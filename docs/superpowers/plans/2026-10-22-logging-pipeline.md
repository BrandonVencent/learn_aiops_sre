# 阶段 3：日志链路实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在三节点 k3s 上部署 Loki 单机模式和 Fluent Bit DaemonSet，把容器 stdout/stderr 采集到 Loki，并在 Grafana 中按 namespace、Pod、level 查询日志，看到一条完整的多行异常堆栈。

**Architecture:** Loki 用 `grafana-community/loki` Helm chart 的 `Monolithic` 模式，单副本、文件系统存储、`local-path` PVC，固定放在 `k8s-worker-2`。Fluent Bit 用 `fluent/fluent-bit` Helm chart 的 DaemonSet 模式，在三个节点上采集 `/var/log/containers/*.log`，通过 Kubernetes filter 补 namespace/pod/container 标签，再推送到 `loki.logging.svc.cluster.local:3100`。Grafana 通过 sidecar 加载 Loki 数据源，不新增 NodePort。另建一个 Python `log-demo` 服务，输出 JSON 日志和 Python traceback，用来验证 level 过滤和多行堆栈。

**Tech Stack:** k3s `v1.36.5+k3s1`、Helm 3、Loki `3.7.9`、Fluent Bit `5.1.3`、LogQL、Grafana、local-path。

**Spec:** `docs/02-lab/00-lab-design.md` 的「阶段 3：日志链路」

## Global Constraints

- 阶段 2 必须已验收：`monitoring` 中 Pod 正常，21 个 target 全部 `up=1`，Grafana 可用。
- Loki 统一放在 `logging` 命名空间，单副本 `Monolithic` 模式，文件系统存储。
- Loki 固定放在 `k8s-worker-2`，PVC 使用 `local-path`，大小 `5Gi`，保留期 7 天。
- Fluent Bit 是 DaemonSet，三个节点都要有一个 Pod；如果 server 有 control-plane taint，必须加 toleration。
- Fluent Bit 只采集容器日志 `/var/log/containers/*.log`，不采集宿主机 systemd 日志。
- 不把 `trace_id`、`level` 做成 Loki stream label，避免高基数；`level` 用 LogQL `| json` 过滤。
- Loki 不暴露 NodePort；Fluent Bit 通过集群内 DNS 访问 Loki。
- Grafana 数据源用 ConfigMap + sidecar 自动加载，不在仓库里记录 Grafana 密码。
- 所有长期运行的组件必须设置 `requests` 和 `limits`。
- 不在仓库里记录 token、密码或私钥。
- 每个新增/修改的 YAML 或 Helm values，必须先用中文解释对象类型、字段作用、数据流、不写或写错的后果、常见错误，再执行；阶段 3 的专题解释在 `docs/02-lab/04-logging-values-explained.md`。
- 阶段 3 只做日志链路，不安装 Tempo/OTel，不做链路追踪。

## Review Focus

- Loki chart 19.x 使用 `deploymentMode: Monolithic`；旧值 `SingleBinary` 已弃用，写错会导致模板或运行异常。
- Loki 的 `gateway` 默认可能启用；如果启用，Fluent Bit 的写入地址会变成 gateway，而不是 `loki:3100`。本计划明确关闭 gateway。
- Fluent Bit chart 默认镜像来自 `cr.fluentbit.io`，k3s 的 registry mirror 只覆盖 `docker.io` 和 `registry.k8s.io`；本计划改用 Docker Hub 的 `fluent/fluent-bit`。
- Fluent Bit 的 CRI 解析和 Python 多行堆栈解析顺序很关键；先用 `multiline.parser cri, python`，验收时确认 traceback 是一个日志条目。
- Loki 标签 `namespace`、`pod`、`container` 已经足够；不要把 `trace_id` 做成标签，否则 stream 数量会爆炸。
- Grafana sidecar 只加载带 `grafana_datasource: "1"` 标签的 ConfigMap；ConfigMap 要放在 Grafana 能搜索到的命名空间。
- `local-path` PVC 是节点本地存储；Loki 固定到 `k8s-worker-2` 后，PVC 只会绑定到该节点，节点磁盘不足会导致 Pending。
- 5Gi 保留 7 天只适合低流量学习环境；如果日志量增长，先缩短保留期或扩容 PVC。
- Fluent Bit 需要读取 `/var/log/containers` 和 Kubernetes API；RBAC 或 hostPath 挂载不对时，Loki 里会完全没有日志。

## File Structure

- Create: `infra/logging/values-loki.yaml` —— Loki Helm values，单机、文件系统、资源、PVC、节点选择。
- Create: `infra/logging/values-fluent-bit.yaml` —— Fluent Bit Helm values，DaemonSet、CRI/Python 多行、Loki 输出。
- Create: `infra/logging/grafana-loki-datasource.yaml` —— Grafana Loki 数据源 ConfigMap。
- Create: `infra/logging/demo-service.yaml` —— 产生 JSON 日志和多行 Python traceback 的 demo 服务。
- Create: `docs/02-lab/04-logging-values-explained.md` —— 四个 YAML/values 的逐段解释。
- Create after acceptance: `docs/02-lab/03-phase-3-acceptance.md` —— 阶段 3 验收记录。
- Modify: `docs/03-qa/2026-10-22.md` —— 记录当天 Loki/Fluent Bit 的实际问题。
- Modify: `docs/03-qa/00-qa-log.md` —— 如有新的每日记录，更新索引。
- Modify: `docs/README.md` —— 增加阶段 3 验收文档入口。
- Modify: `docs/02-lab/00-lab-design.md` —— 标记阶段 3 完成。

---

## Task 0: 阶段 2 收尾与快照

**Files:** 无

**Interfaces:**
- Consumes: 阶段 2 的 `monitoring` 命名空间和 `demo` 工作负载。
- Produces: 一个可回滚的 `phase-2-metrics-ready` 快照；阶段 3 出问题时可以回到这里。

- [ ] **Step 1: 确认集群和阶段 2 仍然健康**

```bash
# 三个节点应该都是 Ready
kubectl get nodes

# demo 两个 Pod 应该都是 1/1；一个 RESTARTS 1，一个新 Pod RESTARTS 0
kubectl get pods -n demo -l app=web

# monitoring 中所有 Pod 应该 Running；Grafana 应该 RESTARTS 0
kubectl get pods -n monitoring

# 三个 PVC 应该都是 Bound
kubectl get pvc -n monitoring
```

Expected: 三个节点 `Ready`；demo 两个 Pod `1/1`；`monitoring` 没有 `CrashLoopBackOff`；PVC 全部 `Bound`。

如果新 Pod 还是 `0/1`：

```bash
kubectl describe pod -n demo web-554647c847-8qq4w
```

先看 readiness 事件，不要带着未解释的异常进入阶段 3。

- [ ] **Step 2: 确认阶段 1 快照是否存在**

在 VMware 的 Snapshot Manager 里检查三台 VM 是否有：

```text
phase-1-k3s-ready
```

如果缺失，在 `docs/02-lab/01-phase-0-1-acceptance.md` 里记录缺失；**不要**把当前阶段 2 状态命名为 `phase-1-k3s-ready`。

- [ ] **Step 3: 打阶段 2 快照**

建议三台 VM 先干净关机，再分别打快照，最后开机：

```bash
# 三台 VM 分别执行
shutdown -h now
```

在 VMware 中给三台 VM 打：

```text
phase-2-metrics-ready
```

开机后重新确认：

```bash
kubectl get nodes
kubectl get pods -n monitoring
kubectl get pods -n demo
```

Expected: 节点和 Pod 恢复到关机前状态；Loki 还没有安装，`logging` 命名空间不存在是正常的。

---

## Task 1: 预检、文件准备和 Helm 仓库

**Files:**
- Create: `infra/logging/values-loki.yaml`
- Create: `infra/logging/values-fluent-bit.yaml`
- Create: `infra/logging/grafana-loki-datasource.yaml`
- Create: `infra/logging/demo-service.yaml`
- Copy to server: `/root/logging/`

**Interfaces:**
- Consumes: 阶段 2 的健康集群、`local-path` StorageClass、Helm。
- Produces: 四个可重复使用的配置文件，以及已添加的 Loki/Fluent Bit chart 仓库。

- [x] **Step 1: 检查节点、taint、存储和内存**

在 `k8s-server` 上执行：

```bash
# 节点和角色
kubectl get nodes -o wide

# 看 server 是否有 control-plane taint；如果有，DaemonSet 需要 toleration
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'

# 确认 local-path 是默认 StorageClass
kubectl get storageclass

# 在 k8s-worker-2 上执行：Loki 会写本地盘，确认空间和内存
df -h /var/lib/rancher/k3s/storage
free -h
```

Expected:
- `local-path (default)` 存在。
- worker-2 的 `/var/lib/rancher/k3s/storage` 至少有 5Gi 可用。
- worker-2 可用内存至少 1Gi；Loki limit 是 1Gi，但节点还要留给系统和 Fluent Bit。
- 如果 server 有 `node-role.kubernetes.io/control-plane:NoSchedule`，后面的 Fluent Bit values 已经加了 toleration。

如果磁盘不足，先把 Loki PVC 改成 3Gi，或换到空间更大的 worker；不要先装再处理 Pending。

- [x] **Step 2: 检查 Helm 仓库和端口占用**

```bash
# 查看已有仓库；Loki 新仓库在 grafana-community，不是旧的 grafana
helm repo list

# 添加 Loki 社区仓库
helm repo add grafana-community https://grafana-community.github.io/helm-charts

# 添加 Fluent Bit 仓库
helm repo add fluent https://fluent.github.io/helm-charts

helm repo update

# 确认 chart 版本可见
helm search repo grafana-community/loki --versions | head -5
helm search repo fluent/fluent-bit --versions | head -5

# Loki 只用 ClusterIP:3100，不应该和现有 Service 冲突
kubectl get svc -A | grep ':3100' || true
```

Expected:
- `grafana-community/loki` 能看到 `19.0.3`（或更高的 19.x）。
- `fluent/fluent-bit` 能看到 `0.58.3`（或更高的 0.58.x）。
- `grep ':3100'` 没有输出。

常见错误：

- `helm repo add` 403/超时：先检查代理和 DNS；GitHub Pages 访问不了时，Loki 可以改用 OCI：

```bash
helm pull oci://ghcr.io/grafana-community/helm-charts/loki --version 19.0.3 --untar -d /tmp
```

- `fluent/fluent-bit` 仓库访问失败：可以用 OCI：

```bash
helm pull oci://ghcr.io/fluent/helm-charts/fluent-bit --version 0.58.3 --untar -d /tmp
```

- [x] **Step 3: 创建 Loki values**

创建 `infra/logging/values-loki.yaml`：

```yaml
# Loki 单机模式（Monolithic），文件系统存储
# 安装命令：helm upgrade --install loki grafana-community/loki -n logging -f values-loki.yaml
deploymentMode: Monolithic

singleBinary:
  enabled: true
  replicas: 1
  # 不使用 ruler/rule ConfigMap，关闭 rules sidecar，避免额外容器
  sidecar: false

  # 放在 worker-2，避免和 server 上的 Prometheus/Grafana 抢内存
  nodeSelector:
    kubernetes.io/hostname: k8s-worker-2

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi

  persistence:
    enabled: true
    storageClass: local-path
    accessModes:
      - ReadWriteOnce
    size: 5Gi

loki:
  # 实验环境不做多租户，Fluent Bit 不需要 X-Scope-OrgID
  auth_enabled: false

  commonConfig:
    replication_factor: 1

  storage:
    type: filesystem

  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  limits_config:
    retention_period: 168h
    allow_structured_metadata: true

  compactor:
    retention_enabled: true
    delete_request_store: filesystem
    working_directory: /var/loki/compactor

# 不用 nginx gateway；Fluent Bit 直接写 loki:3100
gateway:
  enabled: false

# 关闭 canary、MinIO 和查询缓存，节省内存
lokiCanary:
  enabled: false
minio:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false
# chart 默认还会启用 memcached 和 exporter；缓存已关，显式关闭避免多余对象
memcached:
  enabled: false
memcachedExporter:
  enabled: false
# 不使用 ruler 规则，关闭 rules sidecar；该 sidecar 默认没有 requests/limits
sidecar:
  rules:
    enabled: false
test:
  enabled: false

# Monolithic 模式下把分布式组件副本清零
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

注意：

- `deploymentMode` 必须是 `Monolithic`；Loki chart 12+ 已把 `SingleBinary` 标记为旧值。
- `singleBinary.replicas: 1` 是实际运行的 Loki 副本。
- 5Gi 是学习环境的大小；如果要保留更多日志，先确认 worker-2 磁盘。

- [x] **Step 4: 创建 Fluent Bit values**

创建 `infra/logging/values-fluent-bit.yaml`：

```yaml
# Fluent Bit DaemonSet：每个节点采集 /var/log/containers/*.log
kind: DaemonSet

# 默认 chart 用 cr.fluentbit.io；k3s 的 mirror 只覆盖 docker.io/registry.k8s.io，
# 所以改用 Docker Hub，走现有 registry mirror。
image:
  repository: fluent/fluent-bit
  tag: "5.1.3"
  pullPolicy: IfNotPresent

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

# server 节点如果有 control-plane taint，也能运行 Fluent Bit
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

# k3s 使用 containerd，不需要 /var/lib/docker/containers
daemonSetVolumes:
  - name: varlog
    hostPath:
      path: /var/log
  - name: etcmachineid
    hostPath:
      path: /etc/machine-id
      type: File

daemonSetVolumeMounts:
  - name: varlog
    mountPath: /var/log
  - name: etcmachineid
    mountPath: /etc/machine-id
    readOnly: true

config:
  inputs: |
    [INPUT]
        Name tail
        Path /var/log/containers/*.log
        multiline.parser cri, python
        Tag kube.*
        Mem_Buf_Limit 5MB
        Skip_Long_Lines On
        Refresh_Interval 5

  filters: |
    [FILTER]
        Name kubernetes
        Match kube.*
        Merge_Log Off
        Keep_Log On
        K8S-Logging.Parser On
        K8S-Logging.Exclude On

  outputs: |
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

说明：

- `multiline.parser cri, python`：`cri` 处理 containerd 的日志格式，`python` 尝试合并 traceback 的续行。
- `Merge_Log Off`：保留原始 JSON 字符串，避免 Kubernetes filter 把字段拆散；LogQL 用 `| json` 解析。
- `Labels` 只放 namespace/pod/container；不要加 `trace_id`，否则每个 trace 都会变成新 stream。
- `Drop_Single_Key raw`：当记录只剩 `log` 时，直接发送原始多行文本，Grafana 里更容易看到换行。
- `Host` 假设 Loki Service 名称是 `loki`；Task 2 会验证，如果实际名称不同，回来改这里。

- [x] **Step 5: 创建 Grafana Loki 数据源**

创建 `infra/logging/grafana-loki-datasource.yaml`：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: monitoring
  labels:
    # kube-prometheus-stack 的 Grafana datasource sidecar 用这个标签发现配置
    grafana_datasource: "1"
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

注意：

- ConfigMap 必须放在 `monitoring` 命名空间，Grafana sidecar 才会加载。
- `uid: loki` 固定下来，后面文档和 Dashboard 可以引用。
- 不要在 ConfigMap 里写 Grafana 管理员密码。

- [x] **Step 6: 创建 demo 日志服务**

创建 `infra/logging/demo-service.yaml`：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-demo-app
  namespace: demo
data:
  app.py: |
    import json
    import logging
    import sys
    import traceback
    from datetime import datetime, timezone
    from http.server import BaseHTTPRequestHandler, HTTPServer

    logging.basicConfig(
        stream=sys.stdout,
        level=logging.INFO,
        format="%(message)s",
    )

    def emit(level, message, trace_id="demo-trace-001"):
        logging.log(
            getattr(logging, level.upper()),
            json.dumps(
                {
                    "ts": datetime.now(timezone.utc).isoformat(),
                    "level": level,
                    "service": "log-demo",
                    "trace_id": trace_id,
                    "message": message,
                },
                ensure_ascii=False,
            ),
        )

    class Handler(BaseHTTPRequestHandler):
        def _send(self, status, body):
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))

        def do_GET(self):
            if self.path == "/error":
                try:
                    raise RuntimeError("demo error for Loki")
                except RuntimeError:
                    emit("error", "demo error for Loki")
                    traceback.print_exc()
                self._send(500, "error\n")
                return

            emit("info", "hello from log-demo")
            self._send(200, "ok\n")

        def log_message(self, fmt, *args):
            return

    if __name__ == "__main__":
        HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-demo
  namespace: demo
  labels:
    app: log-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-demo
  template:
    metadata:
      labels:
        app: log-demo
    spec:
      containers:
        - name: app
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
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
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: log-demo-app
---
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

说明：

- `/` 输出一行 JSON info 日志。
- `/error` 先输出一行 JSON error 日志，再输出 Python traceback；traceback 是多行日志的验收素材。
- `trace_id` 只放在 JSON 内容里，不做 Loki label。
- demo 命名空间有 ResourceQuota，当前请求 50m/64Mi，不会超限。

- [x] **Step 7: 复制文件到 server**

在 Windows PowerShell 执行：

```powershell
# 把 values 和 manifest 复制到 server
scp -r E:\learn_aiops_sre\infra\logging root@172.25.254.10:/root/logging
```

在 server 上确认：

```bash
ls -l /root/logging
```

Expected: 看到四个文件：`values-loki.yaml`、`values-fluent-bit.yaml`、`grafana-loki-datasource.yaml`、`demo-service.yaml`。

在 server 上做一次 lint。注意：`helm lint` 的第一个参数必须是**本地 chart 目录**，不能直接写 `repo/chart`：

```bash
# 把 chart 拉到本地目录；--untar 会解压成 /tmp/helm-charts/loki
mkdir -p /tmp/helm-charts
helm pull grafana-community/loki --version 19.0.3 --untar -d /tmp/helm-charts
helm pull fluent/fluent-bit --version 0.58.3 --untar -d /tmp/helm-charts

# 用本地 chart 目录做 lint
helm lint /tmp/helm-charts/loki -f /root/logging/values-loki.yaml
helm lint /tmp/helm-charts/fluent-bit -f /root/logging/values-fluent-bit.yaml
```

Expected: 两个 chart 都输出 `1 chart(s) linted, 0 chart(s) failed`。  
如果有 schema 错误，先修 values，不要进入安装。

- [x] **Step 8: 提交配置文件和计划**

```bash
git add infra/logging docs/02-lab/04-logging-values-explained.md \
  docs/03-qa/00-qa-log.md docs/03-qa/2026-10-22.md \
  docs/README.md docs/superpowers/plans/2026-10-22-logging-pipeline.md
git commit -m "feat: add phase 3 logging values and yaml explanations"
```

Expected: 提交成功，工作区没有未提交的 `infra/logging` 文件。

---

## Task 2: 安装 Loki

**Files:**
- Use: `/root/logging/values-loki.yaml`

**Interfaces:**
- Consumes: Task 1 的 Helm 仓库和 Loki values。
- Produces: `logging` 命名空间中的 Loki StatefulSet、Service `loki:3100`、PVC，以及 `/ready` 可用的 Loki 实例。

- [x] **Step 1: 先渲染模板，不直接安装**

```bash
# 检查模板能否正常生成；重点看 Service 名称、镜像、PVC 和 Monolithic 模式
helm template loki grafana-community/loki \
  --namespace logging \
  --version 19.0.3 \
  -f /root/logging/values-loki.yaml > /tmp/loki-rendered.yaml

# 1. 这次会渲染出哪些资源类型
grep -n '^kind:' /tmp/loki-rendered.yaml

# 2. 只看真正的 Service，避免匹配到 ServiceAccount
grep -n -A24 '^kind: Service' /tmp/loki-rendered.yaml | head -100

# 3. StatefulSet 名称、副本和 serviceName
grep -n -A35 '^kind: StatefulSet' /tmp/loki-rendered.yaml | head -60

# 4. 镜像、节点选择、PVC 模板
grep -n 'image:' /tmp/loki-rendered.yaml | head
grep -n -A6 'nodeSelector:' /tmp/loki-rendered.yaml
grep -n -A12 'volumeClaimTemplates:' /tmp/loki-rendered.yaml

# 5. 确认 rules sidecar 已关闭
grep -n 'k8s-sidecar' /tmp/loki-rendered.yaml || echo "OK: 没有 rules sidecar"
```

Expected:
- 渲染成功，没有模板错误。
- 3 个 Service，均为正常对象：
  - `loki`：ClusterIP，端口 `3100`，给 Fluent Bit 和 Grafana 使用。
  - `loki-headless`：StatefulSet 的 headless Service。
  - `loki-memberlist`：headless，端口 `7946`，Loki 内部 memberlist ring 使用。
- 只有 1 个 StatefulSet：`loki`，`replicas: 1`，`serviceName: loki-headless`。
- 镜像为 `docker.io/grafana/loki:3.7.9`。
- `nodeSelector` 为 `kubernetes.io/hostname: k8s-worker-2`。
- `volumeClaimTemplates` 中 `storage: 5Gi`、`storageClassName: local-path`。
- 不应再有 `loki-memcached` 的 ServiceAccount 或 Service；如果还有，检查 `memcached.enabled` 和 `memcachedExporter.enabled` 是否都为 `false`。
- 不应再有 `kiwigrid/k8s-sidecar`；如果还有，检查 `singleBinary.sidecar` 和 `sidecar.rules.enabled` 是否都为 `false`。

如果渲染失败，先把完整错误贴出来；不要继续安装。

- [ ] **Step 2: 安装 Loki**

```bash
# --wait 会等 StatefulSet 的 Pod Ready；超时会返回非 0
helm upgrade --install loki grafana-community/loki \
  --namespace logging \
  --create-namespace \
  --version 19.0.3 \
  -f /root/logging/values-loki.yaml \
  --wait \
  --timeout 10m
```

Expected: 输出 `STATUS: deployed`，并且 `loki-0` 变为 Ready。

- [ ] **Step 3: 检查 Loki Pod、PVC 和 Service**

```bash
kubectl get pods -n logging -o wide
kubectl get pvc -n logging
kubectl get svc -n logging
kubectl get statefulset -n logging
```

Expected:
- `loki-0` 是 `1/1 Running`，节点是 `k8s-worker-2`。
- PVC 是 `Bound`，容量 `5Gi`，StorageClass `local-path`。
- Service `loki` 是 `ClusterIP`，端口 `3100`。
- StatefulSet `loki` 的 READY 是 `1/1`。

常见错误：

- `loki-0` Pending：看 `kubectl describe pod -n logging loki-0`，重点看 nodeSelector、PVC、资源。
- `loki-0` CrashLoopBackOff：看 `kubectl logs -n logging loki-0 --previous`，常见原因是 schema/storage/compactor 配置错误。
- Service 名称不是 `loki`：先不要改 Fluent Bit；把实际名称记下来，Task 3 再调整 `Host`。

- [ ] **Step 4: 验证 Loki 就绪和 metrics**

在 server 上开一个终端做 port-forward：

```bash
kubectl port-forward -n logging svc/loki 3100:3100
```

保持这个终端不关，在另一个终端执行：

```bash
# Loki 的 readiness
curl -s http://127.0.0.1:3100/ready

# 确认 metrics 端点也有响应
curl -s http://127.0.0.1:3100/metrics | head
```

Expected:
- `/ready` 返回 `ready`。
- `/metrics` 返回 Prometheus 文本格式，不是 `connection refused`。

常见错误：

- `connection refused`：port-forward 终端是否还在运行；Service 端口是否真的是 3100。
- `/ready` 一直不是 `ready`：看 `kubectl logs -n logging loki-0`，通常是启动还没完成或配置错误。

- [ ] **Step 5: 记录实际 chart 和镜像版本**

```bash
helm list -n logging
kubectl get pod -n logging loki-0 -o jsonpath='{.spec.containers[0].image}'; echo
```

Expected:
- `loki` release `deployed`。
- 镜像类似 `docker.io/grafana/loki:3.7.9`。

把实际 chart 版本和镜像版本写进阶段 3 验收文档；不要只写计划里的版本。

---

## Task 3: 安装 Fluent Bit

**Files:**
- Use: `/root/logging/values-fluent-bit.yaml`

**Interfaces:**
- Consumes: Task 2 的 Loki Service `loki:3100`。
- Produces: 三个节点上的 Fluent Bit Pod，持续把 `/var/log/containers` 推到 Loki，并生成 `namespace`、`pod`、`container` 标签。

- [ ] **Step 1: 先渲染 Fluent Bit 模板**

```bash
helm template fluent-bit fluent/fluent-bit \
  --namespace logging \
  --version 0.58.3 \
  -f /root/logging/values-fluent-bit.yaml > /tmp/fluent-bit-rendered.yaml

# 看 DaemonSet 和 ConfigMap
grep -n 'kind: DaemonSet' /tmp/fluent-bit-rendered.yaml
grep -n 'kind: ConfigMap' /tmp/fluent-bit-rendered.yaml

# 确认镜像不是 cr.fluentbit.io
grep -n 'image:' /tmp/fluent-bit-rendered.yaml | head
```

Expected:
- 渲染成功。
- DaemonSet 和 ConfigMap 都存在。
- 镜像类似 `fluent/fluent-bit:5.1.3`，不是 `cr.fluentbit.io/...`。

- [ ] **Step 2: 安装 Fluent Bit**

```bash
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace logging \
  --version 0.58.3 \
  -f /root/logging/values-fluent-bit.yaml \
  --wait \
  --timeout 5m
```

Expected: `STATUS: deployed`。

- [ ] **Step 3: 确认三个节点都有一个 Fluent Bit Pod**

```bash
kubectl get ds -n logging
kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit -o wide
```

Expected:
- DaemonSet `DESIRED 3`、`READY 3`、`AVAILABLE 3`。
- 三个 Pod 分别运行在 `k8s-server`、`k8s-worker-1`、`k8s-worker-2`。

如果 `DESIRED 2` 或 server 上没有 Pod：

```bash
kubectl describe node k8s-server | grep -A3 Taints
kubectl describe pod -n logging -l app.kubernetes.io/name=fluent-bit
```

说明：

- 如果 server 有 `NoSchedule` taint，values 里的 toleration 应该已经生效。
- 如果 Pod 是 `Pending`，看节点资源、taint 和 hostPath。

- [ ] **Step 4: 检查 Fluent Bit 自身日志**

```bash
kubectl logs -n logging daemonset/fluent-bit --tail=80
```

Expected:
- 没有 `[error]`、`failed to flush`、`connection refused`。
- 能看到 Loki 输出插件启动的信息。

常见错误：

- `config error` / `unknown plugin`：ConfigMap 缩进或插件名称错误；`kubectl describe configmap -n logging fluent-bit` 检查实际配置。
- `no such file or directory /var/log/containers`：hostPath 挂载不对；确认 values 里的 `daemonSetVolumes` 已生效。
- `403` / `forbidden`：Kubernetes filter 的 RBAC 不足；检查 ClusterRole 和 ServiceAccount。
- `connection refused` 到 Loki：Loki Service 名称/端口不对，或 Loki 未 Ready。

- [ ] **Step 5: 确认 Loki 收到了 Fluent Bit 的日志**

保持 Task 2 的 port-forward（如果没有，重新执行）：

```bash
kubectl port-forward -n logging svc/loki 3100:3100
```

另一个终端：

```bash
# 查看 Loki 当前有哪些 label
curl -s http://127.0.0.1:3100/loki/api/v1/labels | python3 -m json.tool
```

Expected: 至少包含：

```text
container
job
namespace
pod
```

然后查询最近 10 分钟的日志：

```bash
START=$(date -d '10 minutes ago' +%s)000000000
END=$(date +%s)000000000

curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="demo"}' \
  --data-urlencode "start=$START" \
  --data-urlencode "end=$END" \
  --data-urlencode 'limit=5' \
  | python3 -m json.tool
```

Expected:
- `status` 是 `success`。
- `data.result` 不是空数组；能看到 demo web 的 nginx 日志，或者 Fluent Bit 自己的日志。
- 每条结果的 `stream` 里有 `namespace`、`pod`、`container` 标签。

如果结果为空：

```bash
# 先确认 Fluent Bit 有没有读到文件
kubectl exec -n logging daemonset/fluent-bit -- ls -l /var/log/containers | head

# 再看 Fluent Bit 日志
kubectl logs -n logging daemonset/fluent-bit --tail=100
```

常见错误：

- `labels` 为空：Fluent Bit 还没 flush，等 10-20 秒再查；或 output 配置未生效。
- 如果等待后 `labels` 仍为空，先把 output 里的 `Remove_Keys` 和 `Drop_Single_Key` 注释掉，重装 Fluent Bit 再查。这个组合可能在某些版本里先删掉 `kubernetes` 元数据，导致 label 提取不到；确认标签正常后，再逐项加回来验证。
- 查询时间范围不对：Loki 的 API 时间戳是纳秒；用 `date +%s` 后补 9 个 0。
- 只有 Fluent Bit 自己的日志：Kubernetes filter 没有解析出 demo 的 namespace/pod；看 filter 配置和 RBAC。

---

## Task 4: 配置 Grafana Loki 数据源

**Files:**
- Use: `/root/logging/grafana-loki-datasource.yaml`

**Interfaces:**
- Consumes: Task 2 的 `loki:3100`、Task 1 的 ConfigMap。
- Produces: Grafana 中可用的 `Loki` 数据源，Explore 能查询日志。

- [ ] **Step 1: 确认 Grafana 有 datasource sidecar**

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana \
  -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'
```

Expected: 看到类似：

```text
grafana
grafana-sc-dashboard
grafana-sc-datasources
```

如果没有 `grafana-sc-datasources`，需要给阶段 2 的 Helm release 打开 sidecar：

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 92.11.0 \
  -f /root/monitoring/values-kube-prometheus-stack.yaml \
  --set grafana.sidecar.datasources.enabled=true
```

升级前先确认 `/root/monitoring/values-kube-prometheus-stack.yaml` 还在；如果不在，先不要升级，改用 Grafana UI 手工添加数据源，并把情况记录到验收文档。

- [ ] **Step 2: 应用 Loki 数据源 ConfigMap**

```bash
kubectl apply -f /root/logging/grafana-loki-datasource.yaml
kubectl get configmap -n monitoring loki-datasource -o yaml
```

Expected: ConfigMap 创建成功，`data.loki-datasource.yaml` 内容正确，label 有 `grafana_datasource: "1"`。

- [ ] **Step 3: 看 sidecar 是否加载**

```bash
kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana \
  -c grafana-sc-datasources --tail=50
```

Expected: 看到类似：

```text
config from configmap 'loki-datasource' added
```

如果看不到：

- 确认 ConfigMap 在 `monitoring` 命名空间。
- 确认 label 是 `grafana_datasource: "1"`。
- 确认 sidecar 的 `searchNamespace` 不是 `own`；如果是，需要把 ConfigMap 放到 Grafana 所在命名空间或调整 sidecar。

- [ ] **Step 4: 在 Grafana 中验证数据源**

浏览器打开：

```text
http://172.25.254.10:30030
```

进入：

```text
Connections → Data sources → Loki
```

点击 `Save & test`，Expected: 显示数据源连接成功。

然后进入 `Explore`，选择 `Loki`，执行：

```logql
{namespace="demo"}
```

Expected: 能看到 demo 命名空间的日志。

- [ ] **Step 5: 记录 Grafana 数据源配置**

不要在仓库记录 Grafana 密码。验收文档只记录：

```text
数据源名称：Loki
URL：http://loki.logging.svc.cluster.local:3100
类型：loki
```

---

## Task 5: 部署 demo 日志服务并生成日志

**Files:**
- Use: `/root/logging/demo-service.yaml`

**Interfaces:**
- Consumes: `demo` 命名空间和 ResourceQuota。
- Produces: `log-demo` Deployment/Service，能产生 JSON info/error 日志和 Python traceback。

- [ ] **Step 1: 应用 demo 服务**

```bash
kubectl apply -f /root/logging/demo-service.yaml
kubectl rollout status -n demo deploy/log-demo --timeout=120s
kubectl get pods -n demo -l app=log-demo -o wide
kubectl get svc -n demo log-demo
```

Expected:
- `log-demo` Deployment 可用。
- 一个 `log-demo-...` Pod 是 `1/1 Running`。
- Service `log-demo` 是 ClusterIP，端口 8080。

常见错误：

- `ImagePullBackOff`：确认 `python:3.12-slim` 能通过 Docker Hub mirror 拉取；必要时换成本地已有镜像。
- `Pending`：看 ResourceQuota 和节点资源。
- `CrashLoopBackOff`：看 `kubectl logs -n demo deploy/log-demo`，通常是 Python 语法或端口占用。

- [ ] **Step 2: 生成 info 和 error 日志**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import urllib.request

for path in ["/", "/error"]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:8080{path}") as resp:
            print(path, resp.status, resp.read().decode().strip())
    except Exception as exc:
        print(path, type(exc).__name__, exc)
PY
```

Expected:
- `/` 返回 200。
- `/error` 返回 500 或抛出 HTTPError，但 Pod 不会退出。
- `kubectl logs -n demo deploy/log-demo --tail=30` 能看到一行 JSON error 和一段 `Traceback (most recent call last):`。

- [ ] **Step 3: 确认日志进入 Loki**

```bash
kubectl logs -n demo deploy/log-demo --tail=40
```

Expected:

```text
{"ts": "...", "level": "info", "service": "log-demo", "trace_id": "demo-trace-001", "message": "hello from log-demo"}
{"ts": "...", "level": "error", "service": "log-demo", "trace_id": "demo-trace-001", "message": "demo error for Loki"}
Traceback (most recent call last):
  ...
RuntimeError: demo error for Loki
```

在 Grafana Explore 查询：

```logql
{namespace="demo", pod=~"log-demo-.*"}
```

Expected: 能看到 JSON 日志和 traceback。

- [ ] **Step 4: 记录 demo 的 Pod 标签**

```bash
kubectl get pods -n demo -l app=log-demo --show-labels
kubectl get pods -n demo -l app=log-demo -o jsonpath='{.items[0].metadata.name}'; echo
```

Expected: 记下实际 Pod 名，后面用 `pod=~"log-demo-.*"` 或精确 Pod 名查询。

---

## Task 6: LogQL 验收和多行堆栈

**Files:** 无

**Interfaces:**
- Consumes: Task 3 的 Fluent Bit、Task 5 的 demo 日志。
- Produces: 三条可复现的 LogQL 查询，以及多行堆栈是否合并的结论。

- [ ] **Step 1: 按 namespace 和 pod 查询**

在 Grafana Explore 执行：

```logql
{namespace="demo", pod=~"log-demo-.*"}
```

Expected: 返回 `log-demo` 的日志。

再按精确 Pod 名查询：

```logql
{namespace="demo", pod="<实际 Pod 名>"}
```

Expected: 结果和上面一致，只是范围更窄。

- [ ] **Step 2: 按 level 过滤**

```logql
{namespace="demo", pod=~"log-demo-.*"} | json | level="error"
```

Expected:
- 只返回 error JSON 行。
- 不应把 `level` 做成 Loki label；这里是用 `| json` 在查询时解析。

再查 info：

```logql
{namespace="demo", pod=~"log-demo-.*"} | json | level="info"
```

Expected: 只返回 hello 日志。

- [ ] **Step 3: 查询完整多行堆栈**

```logql
{namespace="demo", pod=~"log-demo-.*"} |= "Traceback"
```

Expected:
- 至少返回一条包含 `Traceback (most recent call last):` 的日志。
- 如果 Fluent Bit 的 Python 多行解析生效，这一条日志的 `line` 字段里应包含后续的 `File ...`、`RuntimeError: ...` 多行内容。

如果 traceback 被拆成多条：

```bash
# 先确认 Fluent Bit 读到的是多行还是单行
kubectl logs -n demo deploy/log-demo --tail=40

# 看 Fluent Bit 配置是否真的用了 cri,python
kubectl describe configmap -n logging fluent-bit
```

然后按顺序尝试：

1. 确认 `config.inputs` 里是 `multiline.parser cri, python`，不是 `cri`。
2. 把 `python` 放在 `cri` 后面；不要只写 `python`，否则 CRI 头可能解析不了。
3. 如果仍然拆开，在 `config.filters` 里增加 `multiline` filter：

```text
[FILTER]
    Name multiline
    Match kube.*
    multiline.key_content log
    multiline.parser python
```

改完 values 后执行：

```bash
helm upgrade fluent-bit fluent/fluent-bit \
  --namespace logging \
  --version 0.58.3 \
  -f /root/logging/values-fluent-bit.yaml
```

Expected: 等 10-20 秒后重新查询，traceback 变成一个条目。把最终有效的配置写进验收文档。

- [ ] **Step 4: 查询其他命名空间，确认不是只采集 demo**

```logql
{namespace="monitoring"}
```

Expected: 能看到 Grafana/Prometheus 等 Pod 的日志，说明 DaemonSet 和 Kubernetes filter 在全局工作。

- [ ] **Step 5: 记录验收结果**

至少记录：

```text
查询 1：{namespace="demo", pod=~"log-demo-.*"} -> 有结果
查询 2：... | json | level="error" -> 有结果
查询 3：... |= "Traceback" -> 1 条多行日志 / 或拆成 N 条（如实记录）
查询 4：{namespace="monitoring"} -> 有结果
Loki labels：container, job, namespace, pod
```

再记录资源占用：

```bash
kubectl top pods -n logging
kubectl top pods -n demo -l app=log-demo
kubectl top nodes
```

Expected: Loki 和 Fluent Bit 没有接近 limit；worker-2 还有可用内存。  
如果 Loki 内存接近 `1Gi`，先缩短保留期或降低日志量，不要直接加 limit 把节点压满。

如果多行没有合并，不要写成“通过”；记录实际状态和后续修正。

---

## Task 7: 文档、提交和阶段 3 快照

**Files:**
- Create: `docs/02-lab/03-phase-3-acceptance.md`
- Modify: `docs/03-qa/2026-10-22.md`
- Modify: `docs/03-qa/00-qa-log.md`
- Modify: `docs/README.md`
- Modify: `docs/02-lab/00-lab-design.md`

**Interfaces:**
- Consumes: Task 1–6 的实际输出。
- Produces: 阶段 3 验收记录、可复现命令、Q&A、可回滚快照。

- [ ] **Step 1: 写阶段 3 验收记录**

创建 `docs/02-lab/03-phase-3-acceptance.md`，至少包含：

```text
环境与版本
Loki chart / 镜像 / PVC / 节点
Fluent Bit chart / 镜像 / DaemonSet 数量
Grafana 数据源
LogQL 查询结果
多行 traceback 结果
资源占用
实际遇到的错误和修复
未完成项
```

命令和输出要来自实际执行，不要复制计划里的预期值。

- [ ] **Step 2: 更新 Q&A**

在 `docs/03-qa/2026-10-22.md` 增加阶段 3 当天的问答，至少覆盖：

- 为什么 Loki 单机模式用 `Monolithic` 而不是 `SingleBinary`。
- 为什么 Fluent Bit 用 DaemonSet，不用 Deployment。
- 为什么 `trace_id` 不做 Loki label。
- 为什么 level 过滤用 `| json`，不把 level 做成 label。
- Fluent Bit 的 CRI 和 Python 多行解析为什么要组合。
- Grafana datasource sidecar 的标签和命名空间。
- 镜像 `cr.fluentbit.io` 与 Docker Hub mirror 的区别。

- [ ] **Step 3: 更新索引和实验设计**

在 `docs/README.md` 的阅读顺序增加阶段 3 验收记录。  
在 `docs/02-lab/00-lab-design.md` 的阶段 3 标题下增加：

```text
> 状态：已完成，验收记录见 [阶段 3 日志链路验收记录](03-phase-3-acceptance.md)。
```

- [ ] **Step 4: 提交并推送**

```bash
git add infra/logging docs/02-lab/03-phase-3-acceptance.md docs/03-qa/2026-10-22.md docs/03-qa/00-qa-log.md docs/README.md docs/02-lab/00-lab-design.md
git commit -m "docs: add phase 3 logging acceptance record"
git push
```

Expected: 提交成功；`git status -sb` 显示分支与 `origin` 同步。

- [ ] **Step 5: 打阶段 3 快照**

三台 VM 干净关机后，在 VMware 中打：

```text
phase-3-logging-ready
```

开机后最终确认：

```bash
kubectl get nodes
kubectl get pods -n logging
kubectl get pods -n monitoring
kubectl get pods -n demo
helm list -n logging
```

Expected:
- 三节点 `Ready`。
- Loki `loki-0`、Fluent Bit 三个 Pod、Grafana/Prometheus 等全部正常。
- `logging` 中两个 Helm release 都是 `deployed`。

---

## 回滚方法

如果阶段 3 失败，需要回到阶段 2：

```bash
# 删除 Fluent Bit 和 Loki
helm uninstall fluent-bit -n logging
helm uninstall loki -n logging

# 删除数据源 ConfigMap
kubectl delete -f /root/logging/grafana-loki-datasource.yaml

# 删除 demo 服务
kubectl delete -f /root/logging/demo-service.yaml

# 删除命名空间和 PVC
kubectl delete namespace logging
```

注意：`kubectl delete namespace logging` 会删除 Loki 的 PVC 和日志数据。  
更稳妥的回滚是 VMware 快照 `phase-2-metrics-ready`，它不依赖 Kubernetes 资源删除顺序。

## 完成标准

- Loki `loki-0` 在 `k8s-worker-2` 上 `1/1 Running`，PVC `Bound`。
- Fluent Bit DaemonSet `3/3`，三个节点各一个 Pod。
- Loki labels 至少有 `namespace`、`pod`、`container`、`job`。
- Grafana 中 Loki 数据源可用。
- 能查询 `{namespace="demo"}`。
- 能用 `| json | level="error"` 过滤。
- 能查到一条完整的多行 Python traceback，或如实记录未合并及原因。
- 文档、Q&A、验收记录已提交并推送。
- 三台 VM 有 `phase-3-logging-ready` 快照。
