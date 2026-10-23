# 阶段 4 链路追踪 YAML / Helm values 解释

> 对应文件：
> - `infra/tracing/values-tempo.yaml`
> - `infra/tracing/otel-collector.yaml`
> - `infra/tracing/demo-service-otel.yaml`
> - `infra/logging/grafana-loki-datasource.yaml`
> - `infra/tracing/grafana-tempo-datasource.yaml`
>
> 这篇文档回答：
> 1. 文件是什么类型，谁读取它？
> 2. 每个关键字段在做什么，不写或写错会怎样？
> 3. 它对应 trace 从产生到查询的哪一段？
>
> 实际验收结果见：[阶段 4 链路追踪验收记录](04-phase-4-acceptance.md)。

## 0. 先分清三类文件

### Helm values

```text
infra/tracing/values-tempo.yaml
```

它不是 Kubernetes 资源，不能用 `kubectl apply`。它是 Tempo chart 的输入：

```bash
helm upgrade --install tempo ./tempo-3.2.1.tgz \
  -n tracing \
  --create-namespace \
  -f values-tempo.yaml \
  --wait \
  --timeout 10m
```

Helm 会读取 chart 默认 values，用我们的 values 覆盖，再渲染成 StatefulSet、Service、PVC 等对象。

### Kubernetes manifests

```text
infra/tracing/otel-collector.yaml
infra/tracing/demo-service-otel.yaml
infra/logging/grafana-loki-datasource.yaml
infra/tracing/grafana-tempo-datasource.yaml
```

这些是真正的 Kubernetes 资源，用：

```bash
kubectl apply -f <file>
```

一个文件里可以有多个对象，用 `---` 分隔。

### Grafana provisioning 配置

`grafana-loki-datasource.yaml` 和 `grafana-tempo-datasource.yaml` 都是 ConfigMap。Grafana 的 datasource sidecar 通过标签：

```yaml
labels:
  grafana_datasource: "1"
```

发现它们，并把 `data` 里的 YAML 挂到 Grafana 的 provisioning 目录。

## 1. 全景数据流

```text
应用请求
  |
  v
OpenTelemetry Python SDK
  |  OTLP/HTTP :4318/v1/traces
  v
OTel Collector
  |  OTLP/gRPC :4317
  v
Tempo（文件系统 + PVC）
  |
  v
Grafana Tempo 数据源

应用 stdout
  |
  v
Fluent Bit
  |
  v
Loki
  |
  v
Grafana Loki 数据源
```

两条链路通过日志里的 32 位 `trace_id` 和 Tempo 的 trace ID 关联。

---

## 2. `values-tempo.yaml`

### 2.1 `replicas: 1`

```yaml
replicas: 1
```

Tempo 只运行一个实例。单机文件系统存储下不能简单加副本，因为每个副本会写自己的本地 PVC，数据不共享。

### 2.2 镜像固定

```yaml
tempo:
  registry: docker.io
  repository: grafana/tempo
  tag: "3.1.1"
  pullPolicy: IfNotPresent
```

固定 `3.1.1`，避免 chart 升级时悄悄换 Tempo 版本。`IfNotPresent` 避免每次重启都重新拉镜像。

### 2.3 `resources`

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

- `requests` 决定调度器是否把 Pod 放到节点。
- `limits` 是 cgroup 上限。
- 实测空闲时约 `38Mi`，远低于 `512Mi`；但查询、压缩和 WAL 回放需要余量。
- 如果 limit 太小，Tempo 可能 OOMKilled；如果太大，会挤压同节点的其他组件。

### 2.4 `retention: 168h`

```yaml
retention: 168h
```

Tempo 保留 7 天，和 Loki 的 `168h` 保持一致。保留期不是“查询时隐藏”，而是由 Tempo 的 compaction/retention 机制清理旧 block。学习环境先和日志对齐，避免日志还在、trace 已经没了。

### 2.5 本地文件系统存储

```yaml
storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
```

为什么实验环境不用 S3/MinIO：

- 不需要额外部署 MinIO 和凭据。
- 单机 Tempo 直接写 PVC，路径最短。
- 16 GB 宿主机不适合再堆对象存储。
- 代价是没有多副本、没有跨节点共享，Tempo Pod 必须固定节点。

生产环境通常会把 trace block 放到 S3/GCS/Azure Blob，并让 Tempo 的组件无状态化。

### 2.6 `nodeSelector` 和 PVC

```yaml
nodeSelector:
  kubernetes.io/hostname: k8s-server

persistence:
  enabled: true
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  size: 5Gi
```

`local-path` 的 PV 是节点本地盘，PVC 绑定后 Pod 必须回到同一节点。因此：

- Tempo 固定在 `k8s-server`。
- `storage-tempo-0` 使用 `5Gi`。
- 如果节点改名或磁盘写满，Pod 会 `Pending` 或写入失败。

`local-path` 默认 `WaitForFirstConsumer`：PVC 先 `Pending`，等 Pod 调度后才绑定。这不是故障。

### 2.7 `server.http_listen_port: 3200`

Tempo 的 HTTP API 在 `3200`，Grafana 的 Tempo 数据源通过这个端口查询。`/ready`、`/api/search`、`/api/traces/<id>` 都走它。

### 2.8 OTLP receiver

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
```

Tempo 同时接受 OTLP/gRPC 和 OTLP/HTTP。本阶段实际路径是：

```text
应用 --HTTP 4318--> Collector --gRPC 4317--> Tempo
```

Tempo 的 `4318` 仍然保留，方便以后应用直连或排错。

### 2.9 `metricsGenerator.enabled: false`

本阶段不做 span metrics、service graph 和 Prometheus 远程写。打开后会增加组件和内存，也会引入新的失败点；等基础 trace 链路稳定后再做。

### 2.10 `tempoQuery.enabled: false`

不安装 Jaeger Query 兼容层。Grafana 直接查 Tempo，不需要额外的查询前端。

### 2.11 `serviceMonitor.enabled: false`

暂不接 Prometheus Operator 的 ServiceMonitor，避免和阶段 2 的监控配置耦合。需要监控 Tempo 自身时再单独加。

---

## 3. `otel-collector.yaml`

### 3.1 Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tracing
```

Tempo 和 Collector 放在同一命名空间，Service DNS 更短：

```text
tempo.tracing.svc.cluster.local
otel-collector.tracing.svc.cluster.local
```

### 3.2 `receivers.otlp`

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
```

- 应用使用 OTLP/HTTP `4318`，因为 Python exporter 直接发 HTTP 更简单。
- Collector 也开放 gRPC `4317`，方便以后其他语言 SDK 或服务接入。
- `0.0.0.0` 表示监听容器内所有网卡，不是只监听 localhost。

### 3.3 `processors.memory_limiter`

```yaml
memory_limiter:
  check_interval: 5s
  limit_mib: 96
  spike_limit_mib: 32
```

Collector 容器 limit 是 `128Mi`。这里用：

```text
96Mi + 32Mi = 128Mi
```

含义：

- 每 5 秒检查一次内存。
- 接近上限时先拒绝/丢弃新数据，保护进程不 OOM。
- 不是“超过就扩容”；它是有损保护。

如果 Collector 和 Tempo 的 endpoint 写错，span 可能在这里被丢弃，日志里会看到导出错误。

### 3.4 `processors.batch`

```yaml
batch:
  timeout: 5s
  send_batch_size: 1024
```

Collector 不会每来一个 span 就立刻发给 Tempo，而是批量发送：

- 最多等 5 秒。
- 或攒到 1024 个 span。
- 降低网络请求数，提高吞吐。

验收时请求完成后要等几秒，Tempo 才会出现 trace；这不是丢数据。

### 3.5 `exporters.otlp_grpc`

```yaml
exporters:
  otlp_grpc:
    endpoint: tempo.tracing.svc.cluster.local:4317
    tls:
      insecure: true
```

- Collector 到 Tempo 走 OTLP/gRPC。
- `tls.insecure: true` 只用于集群内明文 gRPC，不是生产推荐。
- `0.163.2` 里 `otlp` 是弃用别名，显式写 `otlp_grpc` 可以避免 warning。
- receiver 仍然叫 `otlp`，不要因为 exporter 改名把 receiver 也改掉。

### 3.6 `extensions.health_check`

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
```

只给 liveness/readiness 探针使用，不放进 Service。探针访问 `/`，健康时返回 200。

### 3.7 `service.pipelines`

```yaml
service:
  extensions:
    - health_check
  pipelines:
    traces:
      receivers:
        - otlp
      processors:
        - memory_limiter
        - batch
      exporters:
        - otlp_grpc
```

只保留 `traces` pipeline：

- 日志已经由 Fluent Bit → Loki 负责。
- 指标已经由 Prometheus 负责。
- 如果 Collector 再采一遍，会重复、增加内存，还会让数据源边界变模糊。

### 3.8 Deployment

关键字段：

```yaml
nodeSelector:
  kubernetes.io/hostname: k8s-worker-1
```

Collector 放在 worker-1，避免和 Tempo 抢 server 内存。

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

实测约 `36Mi`。limit 和 `memory_limiter` 的 `128Mi` 对齐。

```yaml
livenessProbe:
  httpGet:
    path: /
    port: health
readinessProbe:
  httpGet:
    path: /
    port: health
```

探针只检查 Collector 自身健康，不检查 Tempo 是否可达。Tempo 故障时 Collector 仍可能 Ready，但导出会报错；排错时要同时看两边日志。

### 3.9 Service

```yaml
type: ClusterIP
ports:
  - name: otlp-grpc
    port: 4317
  - name: otlp-http
    port: 4318
```

应用通过：

```text
http://otel-collector.tracing.svc.cluster.local:4318/v1/traces
```

发送 span。没有 NodePort，集群外不能直接写入。

---

## 4. `demo-service-otel.yaml`

### 4.1 ConfigMap 和 Deployment 的关系

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-demo-app
data:
  app.py: |
    ...
```

ConfigMap 保存 Python 源码，Deployment 把它挂到 `/app`。改 `app.py` 后：

- 只改 ConfigMap：Pod 不会自动重启，需要 `kubectl rollout restart`。
- 同时改 Deployment 模板：`kubectl apply` 会触发滚动更新。

### 4.2 SDK 初始化

```python
resource = Resource.create({
    "service.name": SERVICE_NAME,
    "service.version": "1.0.0",
    "deployment.environment": "lab",
})
provider = TracerProvider(resource=resource)
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT))
)
trace.set_tracer_provider(provider)
```

- `service.name` 是 Tempo 里识别服务的核心字段。
- `BatchSpanProcessor` 批量导出，默认约 5 秒一批。
- `OTLPSpanExporter` 使用 OTLP/HTTP，endpoint 必须包含 `/v1/traces`。
- `atexit.register(provider.shutdown)` 在正常退出时尽量 flush；进程被 SIGKILL 时不能保证。

### 4.3 trace_id / span_id 注入

```python
def current_ids():
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return "demo-trace-001", "demo-span-001"
    return (
        format(span_context.trace_id, "032x"),
        format(span_context.span_id, "016x"),
    )
```

- 当前 span 有效时，取真实 trace/span ID。
- 32 位和 16 位都是小写十六进制。
- 只有不在 span 内时才退回占位值。如果接入后日志仍是 `demo-trace-001`，说明 span 没有生效。

### 4.4 span 结构

```text
GET /            (SERVER)
  └── demo.hello (INTERNAL)

GET /error       (SERVER, error)
  └── demo.fail  (INTERNAL, error, exception)
```

- `GET /` 是 HTTP 入口 span。
- `demo.hello` 是业务子 span。
- `/error` 记录 exception、设置 error status，并返回 500。
- `trace_id` 在同一个 trace 的所有日志里保持一致。

### 4.5 为什么 readiness 用 `/healthz`

```python
if path == "/healthz":
    self._send(200, "ok\n")
    return
```

这段在创建 span 之前返回。否则 readiness probe 每 5 秒请求一次 `/`，会生成：

- 一条 info 日志；
- 一个 trace；
- 大量污染 Loki 和 Tempo 的探针数据。

### 4.6 `pip install` 启动安装

```yaml
command:
  - sh
  - -c
  - |
    pip install --no-cache-dir --disable-pip-version-check \
      opentelemetry-sdk==1.45.1 \
      opentelemetry-exporter-otlp-proto-http==1.45.1
    exec python -u /app/app.py
```

优点：不用自己构建镜像，版本固定，适合学习。

代价：

- 每次 Pod 启动都要访问 PyPI。
- 第一次启动慢。
- PyPI 不可达时 Pod 不会 Ready。
- 生产环境应该构建自己的镜像，把依赖固化进去。

### 4.7 `startupProbe` 和 `readinessProbe`

```yaml
startupProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 30
```

`5 + 30×5 = 155 秒`左右，给 pip 安装留时间。startupProbe 成功前，readiness/liveness 不会接管。

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    port: http
```

启动后检查 `/healthz`，不会生成 trace 和日志。

### 4.8 资源

```yaml
requests:
  cpu: 100m
  memory: 128Mi
limits:
  cpu: 300m
  memory: 384Mi
```

比阶段 3 的 `64Mi/256Mi` 高，因为要加载 OTel SDK 和 pip 依赖。实测约 `28Mi`。

---

## 5. Loki derived field

```yaml
derivedFields:
  - name: TraceID
    matcherType: regex
    matcherRegex: 'trace_id[^a-f0-9]*([a-f0-9]{32})'
    datasourceUid: tempo
    url: '$${__value.raw}'
    urlDisplayLabel: 'View trace'
    targetBlank: true
```

### 5.1 正则为什么能匹配

Loki 原始行是转义后的 JSON：

```json
{"_p":"F","log":"{\"trace_id\": \"651bd0d1467a24fcc112b750f88f0027\"}"}
```

`trace_id[^a-f0-9]*` 会跳过 `": \"` 这些非十六进制字符，然后捕获 32 位十六进制。

### 5.2 `datasourceUid: tempo`

必须和 Tempo 数据源的 UID 完全一致。写错时链接可能显示，但点开找不到数据源。

### 5.3 `$${__value.raw}`

Grafana provisioning 会做环境变量插值：

- 一个 `$` 可能被当成环境变量。
- 两个 `$$` 是转义，最终 Grafana 看到 `${__value.raw}`。
- `__value.raw` 是正则捕获到的 trace ID。

### 5.4 为什么 `trace_id` 不做 Loki label

Loki label 会建立 stream 索引。`trace_id` 几乎每个请求都不同，做成 label 会导致：

- stream 数量爆炸；
- 索引和内存压力急剧增加；
- 查询反而变慢。

正确做法是把它留在日志内容里，查询时用 `| json` 解析，或用 derived field 提取链接。

---

## 6. Tempo `tracesToLogsV2`

```yaml
tracesToLogsV2:
  datasourceUid: loki
  spanStartTimeShift: '-5m'
  spanEndTimeShift: '5m'
  customQuery: true
  query: '{namespace="demo", pod=~"log-demo-.*"} | json | line_format "{{.log}}" | json | trace_id="$${__trace.traceId}"'
```

### 6.1 `datasourceUid: loki`

必须和 Loki 数据源 UID 一致。

### 6.2 时间偏移

trace 和日志的时间戳不完全相同，前后各留 5 分钟，避免边界误差导致查不到。

### 6.3 自定义查询

因为 Loki 里是两层 JSON：

```text
外层：{"_p":"F","log":"..."}
内层：{"level":"error","trace_id":"..."}
```

所以要：

```logql
| json
| line_format "{{.log}}"
| json
| trace_id="..."
```

如果少了 `line_format`，第二次 `| json` 解析的还是外层，`trace_id` 取不到。

### 6.4 `$${__trace.traceId}`

Tempo 当前 trace 的 ID。Grafana 会替换成十六进制字符串。两个 `$` 同样是 provisioning 转义。

### 6.5 按钮名称

当前 Grafana 版本显示 **Related logs**，旧文档可能写 “Logs for this span”。两者底层都是 `tracesToLogsV2`。

---

## 7. 常见错误

| 现象 | 可能原因 | 先查什么 |
|---|---|---|
| demo 日志还是 `demo-trace-001` | span 没有生效 | 是否在 `start_trace` 之外调用 `emit` |
| Tempo 没有 trace | endpoint 或端口错 | Collector 日志、Tempo `/ready` |
| Tempo 搜索为空 | 搜索 limit/时间范围 | 用 `/api/traces/<id>` 精确查 |
| Collector 报 `otlp` deprecated | 用了旧 exporter 别名 | 改成 `otlp_grpc` |
| 日志每 5 秒一条 | readiness 请求 `/` | 改成 `/healthz`，在 span 前返回 |
| Loki 的 TraceID 不跳转 | UID 或 URL 转义错 | `datasourceUid: tempo`、`$${__value.raw}` |
| Tempo 的 Related logs 为空 | LogQL 没解内层 JSON | 先 `| json | line_format "{{.log}}" | json` |
| Tempo Pod Pending | PVC 节点不匹配 | `kubectl describe pvc storage-tempo-0` |
| Collector OOMKilled | memory_limiter 与 limit 不匹配 | `kubectl describe pod` |

## 8. 验证命令

```bash
# Tempo / Collector 状态
helm list -n tracing
kubectl get sts,pod,pvc,svc -n tracing -o wide

# Collector 日志
kubectl logs -n tracing deploy/otel-collector --tail=80

# Tempo 就绪
kubectl exec -n demo deploy/log-demo -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://tempo.tracing.svc.cluster.local:3200/ready").read().decode())'

# demo 日志
kubectl logs -n demo deploy/log-demo --tail=20

# Grafana 数据源 ConfigMap
kubectl get configmap -n monitoring | grep -E 'loki-datasource|tempo-datasource'

# 资源
kubectl top pods -n tracing
kubectl top nodes
```

## 9. 结论

阶段 4 的关键不是“装上了 Tempo”，而是把三段数据流接起来：

1. 应用生成 span，并把 `trace_id` 写进日志。
2. Collector 接收 OTLP，批量转发给 Tempo。
3. Grafana 通过 UID 和查询模板，把 Loki 日志和 Tempo trace 双向关联。

理解了这三段，才能在生产里判断问题出在 SDK、Collector、Tempo，还是 Grafana 的关联配置。
