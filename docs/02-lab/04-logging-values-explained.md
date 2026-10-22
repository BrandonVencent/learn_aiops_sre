# 阶段 3 日志链路 YAML / Helm values 解释

> 对应文件：
> - `infra/logging/values-loki.yaml`
> - `infra/logging/values-fluent-bit.yaml`
> - `infra/logging/grafana-loki-datasource.yaml`
> - `infra/logging/demo-service.yaml`
>
> 这篇文档回答三个问题：
> 1. 这个文件是什么类型，谁读取它？
> 2. 每个字段在做什么，不写或写错会怎样？
> 3. 它和日志从产生到查询的哪一段有关？

## 0. 先分清两类文件

阶段 3 的四个文件不是同一种东西。

### Helm values

```text
infra/logging/values-loki.yaml
infra/logging/values-fluent-bit.yaml
```

这两个文件不是 Kubernetes 资源，不能用 `kubectl apply`。

它们是 Helm chart 的输入：

```bash
helm upgrade --install loki grafana-community/loki \
  --namespace logging \
  --version 19.0.3 \
  -f /root/logging/values-loki.yaml
```

Helm 会做三件事：

1. 读取 chart 自带的默认 `values.yaml`。
2. 用我们的 values 覆盖默认值。
3. 把 chart 模板渲染成 Kubernetes 对象，再提交给 API Server。

所以 values 里没有 `apiVersion`、`kind: Deployment` 这些字段，它只是“配置数据”。

### Kubernetes manifests

```text
infra/logging/grafana-loki-datasource.yaml
infra/logging/demo-service.yaml
```

这两个文件是真正的 Kubernetes 资源，里面能看到：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ...
```

它们用：

```bash
kubectl apply -f ...
```

一个文件里可以有多个资源，用 `---` 分隔。

---

## 1. 日志链路全景

先看数据怎么走，再看每个字段：

```text
应用容器 stdout/stderr
        |
        v
节点上的 /var/log/containers/*.log
        |
        v
Fluent Bit tail input
        |
        v
multiline parser（cri + python）
        |
        v
Kubernetes filter（补 namespace/pod/container）
        |
        v
Loki output（打标签、决定日志行格式）
        |
        v
Loki Service: loki.logging.svc.cluster.local:3100
        |
        v
Loki 单机进程（写本地文件系统 PVC）
        |
        v
Grafana Loki 数据源 + LogQL
```

四个文件分别负责：

| 文件 | 负责哪一段 |
|---|---|
| `values-loki.yaml` | Loki 怎么部署、数据放哪、保留多久 |
| `values-fluent-bit.yaml` | 从节点读哪些日志、怎么解析、怎么打标签、送到哪 |
| `grafana-loki-datasource.yaml` | Grafana 怎么找到 Loki |
| `demo-service.yaml` | 产生可控的 JSON 日志和多行 traceback 用于验收 |

---

## 2. `values-loki.yaml` 逐段解释

完整文件不长，但每个段落都对应 Loki 的一个行为。

### 2.1 `deploymentMode: Monolithic`

```yaml
deploymentMode: Monolithic
```

Loki chart 支持几种部署模式：

| 模式 | 含义 | 适合场景 |
|---|---|---|
| `Monolithic` | 所有 Loki 组件在同一个进程里 | 单机、学习、小流量 |
| `SimpleScalable` | 读、写、后端分开 | 中等规模 |
| `Microservices` | 每个组件独立部署 | 大规模、生产 |

这里选 `Monolithic`：

- 只需要一个 Loki Pod。
- 不需要分布式缓存、对象存储、读写分离。
- 3 GB 内存的 worker 能承受。
- 和“文件系统存储”匹配。

如果写成旧教程里的 `SingleBinary`，在 chart 19.x 里已经过时，容易和新的 values 结构对不上。

### 2.2 `singleBinary.enabled` 和 `replicas`

```yaml
singleBinary:
  enabled: true
  replicas: 1
```

- `enabled: true`：让 chart 渲染单机模式的工作负载。
- `replicas: 1`：只运行一个 Loki 实例。

为什么不能多副本？

因为存储是 `local-path` 文件系统：

- 每个副本会在自己节点上写自己的 PVC。
- 两个 Loki 实例的数据不共享。
- 查询时可能一个实例有日志、另一个没有。
- 写入也缺少一致性。

学习环境用一个副本，逻辑最简单。

### 2.3 `singleBinary.nodeSelector`

```yaml
nodeSelector:
  kubernetes.io/hostname: k8s-worker-2
```

这表示 Loki Pod 只能调度到 `k8s-worker-2`。

原因是 `local-path`：

- PV 是节点本地盘。
- PVC 绑定后，Pod 必须回到同一节点才能读到数据。
- 固定节点可以避免“Pod 换节点后看不到旧数据”。

如果以后把 worker-2 改名，这里也要改；否则 Pod 会一直 `Pending`。

### 2.4 `singleBinary.resources`

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 1Gi
```

- `requests`：调度器用它判断节点有没有足够资源。
- `limits`：cgroup 上限，超过 CPU 会被限流，超过内存可能被 OOMKilled。

为什么这么设：

- Loki 启动和查询需要内存，256Mi request 是保守值。
- 1Gi limit 给 Loki 留出查询和压缩余量。
- worker-2 有 2.0Gi available，1Gi limit 不会把节点压满。
- CPU 500m 对学习流量足够；日志量大时再调。

如果 limit 太小：

- Loki 可能反复 `OOMKilled`。
- 表现为 Pod `CrashLoopBackOff`，`kubectl describe pod` 里能看到 `OOMKilled`。

如果 limit 太大：

- Loki 真出问题时可能拖垮整个节点。
- 所以要先看 `kubectl top pod -n logging`，再决定是否加。

### 2.5 `singleBinary.persistence`

```yaml
persistence:
  enabled: true
  storageClass: local-path
  accessModes:
    - ReadWriteOnce
  size: 5Gi
```

这是 Loki 的数据盘。

- `enabled: true`：创建 PVC，日志不随 Pod 删除而丢失。
- `storageClass: local-path`：使用 k3s 自带的本地盘 provisioner。
- `accessModes: ReadWriteOnce`：同一时间只能被一个节点挂载。
- `size: 5Gi`：学习环境先给 5Gi。

`local-path` 的绑定模式是 `WaitForFirstConsumer`：

- PVC 创建后不会立刻绑定。
- 等 Loki Pod 调度到 worker-2，provisioner 才在 worker-2 创建 PV。
- 所以 `kubectl get pvc -n logging` 一开始可能是 `Pending`，Pod 调度后才变 `Bound`。

5Gi 能放多少日志取决于日志量和压缩率。学习环境够用；如果接近写满，先缩短保留期，不要直接假设磁盘无限。

### 2.6 `loki.auth_enabled: false`

```yaml
loki:
  auth_enabled: false
```

Loki 支持多租户。开启后，每个请求要带 `X-Scope-OrgID`。

这里关闭：

- Fluent Bit 不需要配置 tenant。
- Grafana 数据源不需要额外 header。
- 学习环境不需要隔离租户。

如果改成 `true` 但客户端没带 tenant，常见现象是 `401` 或 `no org id`。

### 2.7 `loki.commonConfig.replication_factor: 1`

```yaml
commonConfig:
  replication_factor: 1
```

Loki 写入时默认可能要求多个副本确认。

我们只有一个 Loki 实例，所以必须设成 1。否则：

- 写入会等待不存在的副本。
- 可能报 `too many unhealthy ingesters` 或写入超时。

### 2.8 `loki.storage.type: filesystem`

```yaml
storage:
  type: filesystem
```

Loki 的 chunk 和 index 存到本地文件系统，也就是前面的 PVC。

对比其他选项：

| 类型 | 需要什么 | 适合 |
|---|---|---|
| `filesystem` | 本地 PVC | 单机学习 |
| `s3` | S3/MinIO | 生产、可扩展 |
| `gcs` | Google Cloud Storage | GCP |
| `azure` | Azure Blob | Azure |

我们不用 MinIO，所以 `minio.enabled` 后面也会关掉。

### 2.9 `loki.schemaConfig`

```yaml
schemaConfig:
  configs:
    - from: "2024-04-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: loki_index_
        period: 24h
```

这是 Loki 的索引和存储 schema。

- `from`：从哪个日期开始使用这套 schema。
- `store: tsdb`：索引存储类型。
- `object_store: filesystem`：对象存储也是本地文件系统。
- `schema: v13`：Loki 3.x 使用的 schema 版本。
- `index.prefix`：索引文件前缀。
- `index.period: 24h`：索引按天分片。

重要：schema 不是随便改的。以后要升级 schema，正确做法是**追加一条更晚的 `from` 配置**，不要修改旧条目的日期或类型。旧数据还要靠旧 schema 读。

### 2.10 `loki.limits_config.retention_period`

```yaml
limits_config:
  retention_period: 168h
  allow_structured_metadata: true
```

- `retention_period: 168h`：日志保留 7 天。
- `allow_structured_metadata: true`：允许结构化元数据，为以后扩展留口子。

保留期不是“查询时自动隐藏旧日志”这么简单。真正删除旧数据要靠 compactor。

### 2.11 `loki.compactor`

```yaml
compactor:
  retention_enabled: true
  delete_request_store: filesystem
  working_directory: /var/loki/compactor
```

- `retention_enabled: true`：让 compactor 执行保留期删除。
- `delete_request_store: filesystem`：删除请求也放在文件系统；使用 filesystem 存储时必须设置。
- `working_directory`：compactor 的工作目录，放在 PVC 里，避免容器重启后丢失状态。

如果只写 `retention_period` 但不开 compactor：

- 旧日志不会按预期删除。
- 5Gi 磁盘最终会被写满。
- 查询也可能变慢。

### 2.12 `gateway.enabled: false`

```yaml
gateway:
  enabled: false
```

Loki chart 可以额外部署一个 nginx gateway。开启后：

- 客户端访问的是 gateway，不是 Loki 本身。
- Service 名称和端口会变化。
- 多一层代理，多一个组件要排错。

我们让 Fluent Bit 直接写 `loki:3100`，Grafana 也直接查 `loki:3100`，所以关闭 gateway。

如果以后打开 gateway，Fluent Bit 的 `Host` 和 Grafana 数据源 URL 都要改。

### 2.13 `lokiCanary.enabled: false`

```yaml
lokiCanary:
  enabled: false
```

Loki canary 会定期写入测试日志并查询，用来验证 Loki 是否健康。

学习环境先关掉：

- 少一个工作负载。
- 少一些额外日志。
- 需要时再开，用来做健康检查。

### 2.14 `minio.enabled: false`

```yaml
minio:
  enabled: false
```

MinIO 是 S3 兼容对象存储。Loki chart 的某些示例会用 MinIO 存 chunk。

我们用 `filesystem`，不需要 MinIO。关掉可以省内存和 PVC。

### 2.15 `chunksCache`、`resultsCache`、`memcached` 和 `memcachedExporter`

```yaml
chunksCache:
  enabled: false
resultsCache:
  enabled: false
# chart 默认还会启用 memcached 和 exporter；缓存已关，显式关闭避免多余对象
memcached:
  enabled: false
memcachedExporter:
  enabled: false
```

这四个开关要一起理解：

- `chunksCache`：查询 chunk 时用的 Memcached 缓存。
- `resultsCache`：缓存查询结果。
- `memcached`：chart 内置的 Memcached 服务本身。
- `memcachedExporter`：把 Memcached 指标暴露给 Prometheus 的 exporter。

学习环境日志量小，查询缓存不是必需，先全部关闭，省内存和额外对象。

这里有一个容易踩的坑：

- 只写 `chunksCache.enabled: false` 和 `resultsCache.enabled: false`，chart 顶层 `memcached.enabled` 默认仍然是 `true`。
- 结果会渲染出 `loki-memcached` 的 ServiceAccount，甚至多一个 Service。
- 这些对象不影响 Loki 本体，但属于无用资源，也会让“渲染结果是否符合预期”的判断变复杂。

所以必须把 `memcached.enabled` 和 `memcachedExporter.enabled` 也显式设为 `false`。

如果以后查询明显变慢，再考虑打开缓存；打开时要同时给 Memcached 配资源，并重新评估节点内存。

### 2.16 `test.enabled: false`

```yaml
test:
  enabled: false
```

Helm chart 自带的测试 Pod 配置。我们不做 `helm test`，先关掉，减少干扰。

### 2.17 分布式组件 `replicas: 0`

```yaml
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
distributor:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0
bloomPlanner:
  replicas: 0
bloomBuilder:
  replicas: 0
bloomGateway:
  replicas: 0
```

这些是分布式模式的组件。`Monolithic` 模式下不应该再创建它们，所以副本全部设为 0。

注意区分：

- 顶层 `compactor.replicas: 0`：分布式 compactor 组件，不创建。
- `loki.compactor.retention_enabled`：Loki 配置里的 compactor 行为，单机进程里仍然会执行。

这两个不是同一个东西。

---

## 3. `values-fluent-bit.yaml` 逐段解释

这个文件决定“日志怎么被读出来、怎么加工、怎么送到 Loki”。

### 3.1 `kind: DaemonSet`

```yaml
kind: DaemonSet
```

Fluent Bit 要读每个节点上的 `/var/log/containers`，所以每个节点都要有一个 Pod。

- `DaemonSet`：每个节点一个 Pod。
- `Deployment`：副本随机分布，不能保证每个节点都有。

节点上的日志文件是本地的，A 节点的 Fluent Bit 读不到 B 节点的 `/var/log`，所以必须用 DaemonSet。

### 3.2 `image`

```yaml
image:
  repository: fluent/fluent-bit
  tag: "5.1.3"
  pullPolicy: IfNotPresent
```

- `repository`：镜像仓库和名字。
- `tag`：版本，固定为 `5.1.3`，和 chart 的 appVersion 对齐。
- `pullPolicy: IfNotPresent`：节点已有镜像就不重复拉取。

为什么不用 chart 默认的 `cr.fluentbit.io`：

- k3s 的 registry mirror 只覆盖 `docker.io` 和 `registry.k8s.io`。
- `cr.fluentbit.io` 不在 mirror 里，实验网络可能拉取失败。
- Docker Hub 的 `fluent/fluent-bit` 可以走现有 mirror。

如果 Docker Hub 上这个 tag 不存在，回退到 `cr.fluentbit.io` 并记录实际镜像。

### 3.3 `resources`

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

Fluent Bit 很轻，但日志突发时会占内存。

- request 小，保证每个节点都能调度。
- limit 防止日志异常时吃光节点内存。
- `Mem_Buf_Limit 5MB` 还会限制单个输入的内存缓冲。

如果 limit 太小：

- 大量日志时可能频繁垃圾回收、丢日志或 backpressure。
- 看 `kubectl top pod -n logging` 和 Fluent Bit 日志里的 retry/drop 信息。

### 3.4 `tolerations`

```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

Taint 是节点上的“拒绝调度”标记，toleration 是 Pod 的“我可以接受这个 taint”。

当前三个节点没有 taint，所以这段暂时不生效。写上是为了以后给 server 加 control-plane taint 时，Fluent Bit 仍然能跑在 server 上。

### 3.5 `daemonSetVolumes` 和 `daemonSetVolumeMounts`

```yaml
daemonSetVolumes:
  - name: varlog
    hostPath:
      path: /var/log
  - name: etcmachineid
    hostPath:
      path: /etc/machine-id
      type: File
```

```yaml
daemonSetVolumeMounts:
  - name: varlog
    mountPath: /var/log
  - name: etcmachineid
    mountPath: /etc/machine-id
    readOnly: true
```

这两个列表必须成对：

- `daemonSetVolumes` 定义 Pod 能看见哪些宿主机路径。
- `daemonSetVolumeMounts` 决定这些路径挂到容器里的哪里。

为什么挂 `/var/log`：

- `/var/log/containers/*.log` 是 kubelet 为容器日志创建的符号链接。
- 链接指向 `/var/log/pods/...`。
- 挂整个 `/var/log` 后，容器里能同时看到 `containers` 和 `pods`。

为什么挂 `/etc/machine-id`：

- Kubernetes filter 需要节点身份信息。
- 只读挂载，Fluent Bit 不会修改宿主机文件。

为什么删掉 `/var/lib/docker/containers`：

- k3s 用 containerd，不是 Docker。
- 这个路径在节点上不存在，挂载没有意义。
- chart 默认可能包含它，我们用自己的列表覆盖。

### 3.6 `config.inputs`

```ini
[INPUT]
    Name tail
    Path /var/log/containers/*.log
    multiline.parser cri, python
    Tag kube.*
    Mem_Buf_Limit 5MB
    Skip_Long_Lines On
    Refresh_Interval 5
```

逐行解释：

- `Name tail`：跟踪文件尾部，类似 `tail -F`。
- `Path`：读取所有容器的 CRI 日志文件。
- `multiline.parser cri, python`：
  - `cri` 先解析 containerd 的日志头：时间、stream、tag。
  - `python` 再尝试把 `Traceback` 和后续缩进行合成一个日志条目。
  - 顺序很重要；只写 `python` 可能解析不了 CRI 头。
- `Tag kube.*`：给记录打内部标签，后面的 filter/output 用 `Match kube.*` 匹配。
- `Mem_Buf_Limit 5MB`：每个输入的内存缓冲上限，防止日志洪水吃光内存。
- `Skip_Long_Lines On`：遇到超长行不阻塞整个采集；可能截断/跳过超长内容。
- `Refresh_Interval 5`：每 5 秒重新扫描一次新文件。

### 3.7 `config.filters`

```ini
[FILTER]
    Name kubernetes
    Match kube.*
    Merge_Log Off
    Keep_Log On
    K8S-Logging.Parser On
    K8S-Logging.Exclude On
```

Kubernetes filter 会调用 Kubernetes API，给日志补元数据：

- `namespace_name`
- `pod_name`
- `container_name`
- `node_name`
- Pod labels/annotations

逐项解释：

- `Name kubernetes`：使用 Kubernetes filter。
- `Match kube.*`：只处理 tail 打上 `kube.*` 的记录。
- `Merge_Log Off`：不把 JSON 日志拆开合并到记录顶层，保留原始 `log` 字段。
- `Keep_Log On`：保留原始日志内容。
- `K8S-Logging.Parser On`：允许 Kubernetes 注解影响解析器。
- `K8S-Logging.Exclude On`：允许通过 Pod 注解排除某些日志。

为什么 `Merge_Log Off`：

- 我们的应用输出 JSON，希望 Loki 里保存原始 JSON 行。
- LogQL 用 `| json` 在查询时解析，不需要 Fluent Bit 提前拆字段。
- 如果 `Merge_Log On`，字段会被合并到记录顶层，`log` 可能不再完整，后续 `Drop_Single_Key raw` 的行为也会变。

### 3.8 `config.outputs`

```ini
[OUTPUT]
    Name loki
    Match kube.*
    Host loki.logging.svc.cluster.local
    Port 3100
    Labels job=fluent-bit, namespace=$kubernetes['namespace_name'], pod=$kubernetes['pod_name'], container=$kubernetes['container_name']
    Line_Format json
    Remove_Keys kubernetes,stream,time
    Drop_Single_Key raw
    Retry_Limit False
```

逐项解释：

- `Name loki`：使用 Loki 输出插件。
- `Match kube.*`：把 Kubernetes filter 处理过的记录送到 Loki。
- `Host`：Loki Service 的集群内 DNS。
- `Port 3100`：Loki HTTP 端口。
- `Labels`：决定 Loki 的 stream label。
  - `job=fluent-bit`：固定标签，表示来源。
  - `namespace`、`pod`、`container`：从 Kubernetes 元数据取。
  - 没有 `level`、`trace_id`：避免高基数。
- `Line_Format json`：把记录序列化成 JSON 行。
- `Remove_Keys kubernetes,stream,time`：标签提取后，移除不需要写入日志行的元数据。
- `Drop_Single_Key raw`：如果记录只剩一个 `log` 字段，直接发送原始字符串，保留多行换行。
- `Retry_Limit False`：Loki 不可用时无限重试；配合 `Mem_Buf_Limit` 防止无限占内存。

为什么 `level` 不做标签：

- 每个 level 组合都会产生新的 stream。
- 如果以后把 `trace_id` 也做标签，每个请求一个 stream，Loki 会被高基数拖垮。
- level 是日志内容的一部分，查询时用：

```logql
{namespace="demo", pod=~"log-demo-.*"} | json | level="error"
```

### 3.9 日志进入 Loki 后的样子

应用输出：

```json
{"level":"info","service":"log-demo","message":"hello"}
```

经过 Fluent Bit 后，Loki 里大致是：

```text
labels: {job="fluent-bit", namespace="demo", pod="log-demo-...", container="app"}
line:   {"level":"info","service":"log-demo","message":"hello"}
```

Python traceback 经过 `python` parser 后，理想情况是一个多行 `line`：

```text
Traceback (most recent call last):
  File "/app/app.py", line 42, in do_GET
    raise RuntimeError("demo error for Loki")
RuntimeError: demo error for Loki
```

如果 traceback 被拆成多条，先检查 `multiline.parser` 和 `Drop_Single_Key` 的组合；计划里已经写了回退步骤。

---

## 4. `grafana-loki-datasource.yaml` 逐段解释

### 4.1 为什么用 ConfigMap

Grafana 支持通过配置文件自动加载数据源。`kube-prometheus-stack` 的 Grafana 有一个 sidecar 容器，会监听带特定标签的 ConfigMap。

这样数据源可以进 Git，重建 Grafana 后不用手工点 UI。

### 4.2 `metadata.namespace: monitoring`

```yaml
namespace: monitoring
```

Grafana 在 `monitoring` 命名空间。ConfigMap 放这里，sidecar 最容易发现。

### 4.3 `grafana_datasource: "1"`

```yaml
labels:
  grafana_datasource: "1"
```

这是 sidecar 的发现标签。

没有这个标签：

- ConfigMap 只是普通配置，不会变成 Grafana 数据源。
- Grafana UI 里看不到 Loki。

### 4.4 `data` 里的 provisioning YAML

```yaml
data:
  loki-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki.logging.svc.cluster.local:3100
        isDefault: false
        editable: false
        jsonData:
          maxLines: 1000
```

- `apiVersion: 1`：Grafana provisioning 的版本，不是 Kubernetes API 版本。
- `datasources`：可以放多个数据源。
- `name: Loki`：Grafana 里显示的名字。
- `uid: loki`：稳定 ID，Dashboard 可以引用。
- `type: loki`：数据源类型。
- `access: proxy`：Grafana 后端代理请求，浏览器不直接访问 Loki。
- `url`：Loki Service 的集群内地址。
- `isDefault: false`：不抢默认数据源。
- `editable: false`：UI 里不能随便改，配置以 Git 为准。
- `jsonData.maxLines: 1000`：单次查询最多返回 1000 行，防止一次拉太多。

### 4.5 为什么没有密码

Loki 配置了 `auth_enabled: false`，不需要认证。

不要在这里写 Grafana 管理员密码，也不要写任何 token。Grafana 自己的密码由 Grafana 管理，不放进这个 ConfigMap。

### 4.6 sidecar 不生效时

检查：

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana \
  -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'
```

如果没有 `grafana-sc-datasources`，说明 sidecar 没开。计划里给了两种处理：

1. 用 Helm 打开 `grafana.sidecar.datasources.enabled=true`。
2. 临时在 Grafana UI 手工添加，并记录为偏差。

---

## 5. `demo-service.yaml` 逐段解释

这个文件有三个资源：

```text
ConfigMap  log-demo-app
Deployment log-demo
Service    log-demo
```

### 5.1 ConfigMap：把 Python 代码挂进容器

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-demo-app
  namespace: demo
data:
  app.py: |
    ...
```

- ConfigMap 存非敏感配置。
- `app.py` 是键名，内容是一段 Python 源码。
- 后面 Deployment 把它挂到 `/app`，容器里就有 `/app/app.py`。

为什么不用自己构建镜像：

- 学习阶段不想引入镜像构建、推送、仓库。
- 用官方 `python:3.12-slim`，代码通过 ConfigMap 注入。
- 改代码只需要改 ConfigMap，重新 rollout 即可。

### 5.2 Python 代码在做什么

核心逻辑：

```python
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(message)s",
)
```

- 日志写到 stdout。
- 只输出消息本身，格式由我们自己控制。
- 容器运行时会把 stdout/stderr 写成 CRI 日志文件。

```python
def emit(level, message, trace_id="demo-trace-001"):
    logging.log(
        getattr(logging, level.upper()),
        json.dumps({
            "ts": ...,
            "level": level,
            "service": "log-demo",
            "trace_id": trace_id,
            "message": message,
        }),
    )
```

每条日志是一个 JSON 对象：

- `ts`：时间。
- `level`：`info` 或 `error`。
- `service`：服务名。
- `trace_id`：演示字段，只在 JSON 内容里，不做 Loki label。
- `message`：人类可读消息。

`/` 路径：

```python
emit("info", "hello from log-demo")
```

`/error` 路径：

```python
try:
    raise RuntimeError("demo error for Loki")
except RuntimeError:
    emit("error", "demo error for Loki")
    traceback.print_exc()
```

这里故意做两件事：

1. 输出一行 JSON error，用于 `| json | level="error"`。
2. 用 `traceback.print_exc()` 输出多行 Python 堆栈，用于多行日志验收。

`traceback.print_exc()` 默认写 stderr；CRI 日志文件同样会记录，Fluent Bit 也能读到。

### 5.3 Deployment

```yaml
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-demo
  template:
    metadata:
      labels:
        app: log-demo
```

- `replicas: 1`：一个 Pod 就够产生日志。
- `selector` 必须匹配 `template.metadata.labels`；写错会导致 Deployment 不管理 Pod。
- `selector` 创建后不可随便改，否则 `kubectl apply` 会报 immutable。

容器部分：

```yaml
containers:
  - name: app
    image: python:3.12-slim
    command: ["python", "/app/app.py"]
    ports:
      - name: http
        containerPort: 8080
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

- `command` 覆盖镜像默认入口，直接跑我们的脚本。
- `containerPort` 只是声明，真正监听在 Python 代码里。
- `resources` 满足 `demo` 命名空间的 ResourceQuota 和 LimitRange。
- 没有设置 `securityContext`，学习环境先保持简单。

健康检查：

```yaml
readinessProbe:
  httpGet:
    path: /
    port: http
  initialDelaySeconds: 2
  periodSeconds: 5
```

- Pod 启动 2 秒后开始检查 `/`。
- 返回 200 才算 Ready。
- 如果代码语法错、端口没监听，Pod 会 `0/1`，不会接流量。

挂载：

```yaml
volumeMounts:
  - name: app
    mountPath: /app
volumes:
  - name: app
    configMap:
      name: log-demo-app
```

- 把 ConfigMap `log-demo-app` 挂到 `/app`。
- 键 `app.py` 就变成 `/app/app.py`。
- 修改 ConfigMap 后，文件内容会更新，但 Python 进程不会自动重载；需要 `kubectl rollout restart`。

### 5.4 Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: log-demo
  namespace: demo
spec:
  selector:
    app: log-demo
  ports:
    - name: http
      port: 8080
      targetPort: http
```

- `selector` 选中 `app: log-demo` 的 Pod。
- `port: 8080`：Service 对外端口。
- `targetPort: http`：转发到容器名为 `http` 的端口（8080）。
- 默认类型是 `ClusterIP`，只在集群内可访问。

集群内地址：

```text
log-demo.demo.svc.cluster.local:8080
```

不需要 NodePort，因为我们只是用 `kubectl exec` 或临时 Pod 触发日志。

### 5.5 资源配额 interaction

`demo` 命名空间有：

```text
requests.cpu: 2
requests.memory: 2Gi
limits.cpu: 4
limits.memory: 4Gi
pods: 20
```

`log-demo` 请求 `50m/64Mi`，限额 `200m/256Mi`，完全放得下。

如果加副本或加大资源，先看：

```bash
kubectl describe quota -n demo
```

---

## 6. 四个文件如何配合

```text
1. Helm 安装 Loki
   values-loki.yaml
   -> StatefulSet loki-0
   -> Service loki:3100
   -> PVC 5Gi on worker-2

2. Helm 安装 Fluent Bit
   values-fluent-bit.yaml
   -> DaemonSet 3 个 Pod
   -> 读 /var/log/containers
   -> 写 http://loki.logging.svc.cluster.local:3100

3. 应用数据源 ConfigMap
   grafana-loki-datasource.yaml
   -> Grafana sidecar 发现
   -> Grafana 里出现 Loki 数据源

4. 应用 demo 服务
   demo-service.yaml
   -> Python 进程输出 JSON / traceback
   -> 节点日志文件
   -> Fluent Bit
   -> Loki
   -> Grafana Explore
```

任何一段断掉，症状不同：

| 症状 | 可能原因 |
|---|---|
| Grafana 没有 Loki 数据源 | ConfigMap 标签/命名空间不对，sidecar 没开 |
| 有数据源但查询为空 | Fluent Bit 没采到日志，或 Loki 没收到 |
| 有日志但没有 namespace/pod 标签 | Kubernetes filter 或 label 配置有问题 |
| `| json` 过滤不到 level | 日志不是 JSON，或字段名不是 `level` |
| traceback 被拆成多条 | `multiline.parser` 没生效 |
| Loki Pod Pending | nodeSelector/PVC/资源不足 |
| Loki 写满磁盘 | 保留期/compactor 没生效，或日志量超预期 |

---

## 7. 读 YAML 的通用方法

看到任何一个 Kubernetes YAML，按这个顺序读：

1. `apiVersion` + `kind`：这是什么对象。
2. `metadata.name` + `namespace`：它叫什么、放哪。
3. `spec`：它的期望状态。
4. `selector` / `labels`：它和谁关联。
5. `template`：Pod 长什么样。
6. `volumes` / `volumeMounts`：文件从哪来、挂到哪。
7. `resources`：调度和限制。
8. `ports` / `service`：流量怎么进。

看到 Helm values，按这个顺序读：

1. 这个值对应 chart 的哪个组件。
2. 这个值是开关、副本数、资源，还是组件配置。
3. 不写时 chart 默认是什么。
4. 写错时是模板错误、调度失败，还是运行时空闲/报错。

常用验证：

```bash
# 看 chart 最终渲染成什么
helm template loki grafana-community/loki -n logging -f values-loki.yaml

# 检查 values 和模板
helm lint /tmp/helm-charts/loki -f values-loki.yaml

# 检查 manifest 语法和 API
kubectl apply --dry-run=client -f demo-service.yaml
kubectl apply --dry-run=server -f demo-service.yaml

# 看字段文档
kubectl explain deployment.spec.template.spec.containers.resources
```

---

## 8. 阶段 3 验收和这些字段的对应关系

| 验收项 | 依赖哪个配置 |
|---|---|
| 按 namespace 查询 | Fluent Bit `Labels` 里的 `namespace` |
| 按 pod 查询 | Fluent Bit `Labels` 里的 `pod` |
| 按 level 过滤 | demo JSON 的 `level` + LogQL `| json` |
| 多行 traceback | Fluent Bit `multiline.parser cri, python` |
| Grafana 能查 Loki | `grafana-loki-datasource.yaml` + sidecar |
| 日志能持久化 | `singleBinary.persistence` + `local-path` |
| 7 天保留 | `retention_period` + compactor |
| 资源不压垮节点 | `resources` requests/limits |

---

## 9. 变更时的检查清单

改 Loki：

- 改节点：同步改 `nodeSelector`，并确认新节点磁盘。
- 改存储大小：`local-path` 不支持自动扩容；需要重建 PVC 或迁移数据。
- 改保留期：同时确认 compactor 开启。
- 改副本数：不要在用本地文件系统时盲目加副本。
- 改 gateway：同步改 Fluent Bit Host 和 Grafana URL。

改 Fluent Bit：

- 改镜像：确认 registry mirror 和 tag。
- 改 parser：先看 CRI 头和 traceback 是否仍能解析。
- 改 labels：不要加高基数字段。
- 改 output：先确认 Loki Service 名称和端口。
- 改 hostPath：确认节点上路径存在，且容器有读权限。

改数据源：

- 改 URL：确认 Grafana 能解析 DNS。
- 改 namespace/label：sidecar 可能发现不了。
- 改 uid：引用它的 Dashboard 会断。

改 demo：

- 改日志字段：同步改 LogQL。
- 改端口：同步改 Service `targetPort` 和 readinessProbe。
- 改资源：先看 ResourceQuota。
