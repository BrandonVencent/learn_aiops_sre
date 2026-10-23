# 阶段 4 链路追踪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 k3s 实验集群上打通 `demo 应用 → OTel Collector → Tempo → Grafana` 的链路追踪，并让 Loki 日志里的 `trace_id` 能跳到 Tempo，Tempo 也能反查同一 trace 的 Loki 日志。

**Architecture:** Tempo 用 `grafana-community/tempo` Helm chart 的单机模式，文件系统存储、`local-path` PVC、保留 7 天，固定放在 `k8s-server`。OTel Collector 用普通 Kubernetes 清单部署在 `k8s-worker-1`，只接收 OTLP trace，再通过 gRPC 转发给 Tempo。现有 `log-demo` 改成带 OpenTelemetry Python SDK 的版本，通过 OTLP/HTTP 把 span 发给 Collector，同时把 32 位 `trace_id` 和 `span_id` 写进 JSON 日志。Grafana 增加 Tempo 数据源，并在 Loki 数据源上增加 derived field，完成日志和链路双向跳转。

**Tech Stack:** k3s `v1.36.5+k3s1`、Helm `v3.22.1`、Grafana Tempo chart `3.2.1`（Tempo `3.1.1`）、OpenTelemetry Collector Contrib `0.163.2`、OpenTelemetry Python `1.45.1`、Grafana provisioning。

**Spec:** [`docs/02-lab/00-lab-design.md` 阶段 4](../../02-lab/00-lab-design.md#阶段-4链路追踪可选内存允许再做)

## Global Constraints

- 所有命令在 `k8s-server` 上以 `root` 执行，不使用 `sudo`。
- 用户手动执行命令；助手负责解释每个新 YAML、给出命令和预期输出。不要在用户确认前批量执行。
- 不记录 Grafana 管理员密码、token、私钥或任何 Secret 明文。
- 不修改 Loki 和 Fluent Bit 的采集配置；阶段 3 的日志链路必须保持可用。
- 不把 `trace_id` 做成 Loki label；`trace_id` 只存在于日志正文和 trace 中。
- Tempo 和 Collector 只用 `ClusterIP`，不新增 NodePort。
- Tempo 使用 `grafana-community/tempo` chart `3.2.1`，镜像 `grafana/tempo:3.1.1`。
- Collector 使用 `otel/opentelemetry-collector-contrib:0.163.2`，普通 Deployment，1 副本。
- Python 依赖固定为 `opentelemetry-sdk==1.45.1`、`opentelemetry-exporter-otlp-proto-http==1.45.1`。
- Tempo 资源：requests `100m/256Mi`，limits `500m/512Mi`；Collector：requests `50m/64Mi`，limits `200m/128Mi`。
- Tempo PVC：`local-path`，`5Gi`，保留 7 天（`168h`）。
- 现有 Loki 数据源 UID 保持 `loki`；新 Tempo 数据源 UID 固定 `tempo`。
- 所有新 YAML 必须先做 `kubectl apply --dry-run=client` 或 `helm template`，再实际应用。

## Review Focus

1. **嵌套 JSON 的日志关联**：Loki 行是 `{"_p":"F","log":"{\"trace_id\":\"...\"}"}`，Loki derived field 和 Tempo 的 `tracesToLogsV2` 自定义 LogQL 必须能解析内层 JSON；否则日志与 trace 互相跳转为空。
2. **应用启动时安装 OTel 依赖**：`pip install` 可能因网络或版本问题失败；startupProbe 要给足时间，应用失败时先看日志，不要静默改成假 trace。
3. **Tempo 本地存储权限**：Tempo 默认以 UID `10001` 运行，`local-path` PVC 的权限或 fsGroup 不合适会导致启动失败；PVC 必须 `Bound`，Pod 不能反复重启。
4. **OTLP 协议和端口**：应用用 OTLP/HTTP `4318` 发 Collector，Collector 用 OTLP/gRPC `4317` 发 Tempo；协议或 Service DNS 写错时 Tempo 不会收到任何 trace。
5. **Grafana sidecar 热加载**：ConfigMap 更新后 sidecar 可能未加载或出现认证错误；修改后重启 Grafana，并确认数据源列表里只有预期的 `Loki` 和 `Tempo`。

---

### Task 0: 基线检查与 chart 确认

**Files:**
- 无文件修改。

**Interfaces:**
- Consumes: 阶段 3 的 `logging`、`monitoring`、`demo` 命名空间和 `phase-3-logging-ready` 快照。
- Produces: 当前节点、Pod、内存基线，以及 Tempo chart 实际版本。

- [ ] **Step 1: 确认集群和阶段 3 仍然正常**

```bash
kubectl get nodes
kubectl get pods -n logging
kubectl get pods -n demo
kubectl top nodes
```

Expected:
- 三个节点全部 `Ready`。
- `fluent-bit-*` 和 `loki-0` 全部 `1/1 Running`。
- `log-demo` 为 `1/1 Running`。
- `k8s-server` 内存不要超过 75%；如果超过，先停下来重新评估 Tempo 放哪里。

- [ ] **Step 2: 确认 Helm 仓库和 Tempo chart 版本**

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update
helm search repo grafana-community/tempo --versions | head -10
helm show chart grafana-community/tempo --version 3.2.1
```

Expected:
- 能找到 `grafana-community/tempo`。
- chart 版本为 `3.2.1`，`appVersion` 为 `3.1.1`。
- 如果 `3.2.1` 不存在，停止并记录实际版本，不要直接换版本继续。

- [ ] **Step 3: 把实际结果记到今天 Q&A 的“实际结果”区**

只记录版本和资源数字，不记录任何密码或 token。

---

### Task 1: 部署 Tempo 单机模式

**Files:**
- Create: `infra/tracing/values-tempo.yaml`
- Later: `docs/02-lab/05-tracing-values-explained.md`（Task 6 补完整解释）

**Interfaces:**
- Consumes: `tracing` 命名空间、`local-path` StorageClass。
- Produces:
  - Service `tempo.tracing.svc.cluster.local:3200`：Tempo HTTP API。
  - Service `tempo.tracing.svc.cluster.local:4317`：OTLP/gRPC。
  - Service `tempo.tracing.svc.cluster.local:4318`：OTLP/HTTP。
  - StatefulSet `tempo`，Pod `tempo-0`，PVC `storage-tempo-0`。

- [ ] **Step 1: 创建 `infra/tracing/values-tempo.yaml`**

```yaml
# Grafana Tempo 单机模式（chart 内部就是 Single Binary）
# 安装命令：
# helm upgrade --install tempo grafana-community/tempo \
#   -n tracing --create-namespace --version 3.2.1 \
#   -f values-tempo.yaml --wait --timeout 10m

replicas: 1

tempo:
  # 固定镜像版本，避免 chart 升级时悄悄换 Tempo
  registry: docker.io
  repository: grafana/tempo
  tag: "3.1.1"
  pullPolicy: IfNotPresent

  # 实验环境：单进程处理所有角色
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # 关闭匿名使用统计
  reportingEnabled: false

  # 允许 Grafana 通过 HTTP 流式查询
  streamOverHttpEnabled: true

  # 只保留 7 天，和 Loki 保持一致
  retention: 168h

  # 单机文件系统存储；生产环境应换对象存储
  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces
      wal:
        path: /var/tempo/wal

  server:
    http_listen_port: 3200

  # 只保留 OTLP receiver；Collector 通过 4317/4318 发进来
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

# 放在 server 节点：内存 6 GB，磁盘 60 GB，适合做追踪后端
nodeSelector:
  kubernetes.io/hostname: k8s-server

# 持久化 trace 和 WAL
persistence:
  enabled: true
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  size: 5Gi

service:
  type: ClusterIP

# 不安装 Jaeger Query 兼容层，节省内存；Grafana 直接查 Tempo
tempoQuery:
  enabled: false

# 暂不接 Prometheus Operator 的 ServiceMonitor
serviceMonitor:
  enabled: false
```

- [ ] **Step 2: 解释 YAML 后再拷贝到 server**

在聊天里逐段说明：
- `replicas` 和 `tempo.resources`：单副本和内存上限。
- `storage.trace.backend: local`：为什么实验环境用文件系统而不是 S3/MinIO。
- `nodeSelector`：为什么放 `k8s-server`。
- `persistence`：PVC 大小和 `local-path` 的行为。

拷贝：

```bash
mkdir -p /root/tracing
scp infra/tracing/values-tempo.yaml root@172.25.254.10:/root/tracing/
```

- [ ] **Step 3: 渲染并检查对象**

```bash
cd /root/tracing
helm template tempo grafana-community/tempo \
  -n tracing \
  --version 3.2.1 \
  -f values-tempo.yaml > tempo-rendered.yaml

grep -nE 'kind: (StatefulSet|Service|PersistentVolumeClaim)|image: .*tempo|storageClass|block_retention|nodeSelector|k8s-server|3200|4317|4318' tempo-rendered.yaml
```

Expected:
- 有 `StatefulSet`、`Service`，PVC 由 StatefulSet 的 `volumeClaimTemplates` 生成。
- 镜像为 `docker.io/grafana/tempo:3.1.1`。
- 能看到 `k8s-server`、`3200`、`4317`、`4318`。
- 能看到 `block_retention: 168h`（或等价的 `168h0m0s`）。
- 如果 `jaeger` receiver 仍然存在，不影响本阶段；不要为了删它改坏 chart 默认配置。

- [ ] **Step 4: 安装 Tempo**

```bash
helm upgrade --install tempo grafana-community/tempo \
  -n tracing \
  --create-namespace \
  --version 3.2.1 \
  -f /root/tracing/values-tempo.yaml \
  --wait \
  --timeout 10m
```

Expected:
- 输出 `STATUS: deployed`。
- 如果超时，先执行 `kubectl get pod,pvc -n tracing`，不要连续重装。

- [ ] **Step 5: 验证 Tempo Pod、PVC 和 Service**

```bash
kubectl get statefulset,pod,pvc,svc -n tracing -o wide
kubectl logs -n tracing tempo-0 --tail=80
```

Expected:
- `tempo-0` 为 `1/1 Running`，`RESTARTS 0`。
- `storage-tempo-0` 为 `Bound`。
- Service `tempo` 有 `3200`、`4317`、`4318` 端口。
- 日志中没有 `permission denied`、`failed to create`、`no such file`。

- [ ] **Step 6: 从集群内验证 Tempo 就绪和 API**

```bash
kubectl run tempo-check --rm -it --restart=Never \
  --image=curlimages/curl:8.12.1 \
  --command -- curl -sS http://tempo.tracing.svc.cluster.local:3200/ready
```

Expected:
- 返回 `ready`。
- 如果 Pod 一直 `ImagePullBackOff`，先检查镜像仓库网络，不要改 Tempo 配置。

- [ ] **Step 7: 提交 Tempo 配置**

```bash
git add infra/tracing/values-tempo.yaml
git commit -m "feat: add tempo tracing backend"
```

---

### Task 2: 部署 OTel Collector

**Files:**
- Create: `infra/tracing/otel-collector.yaml`

**Interfaces:**
- Consumes:
  - Tempo OTLP/gRPC `tempo.tracing.svc.cluster.local:4317`。
  - 应用 OTLP/HTTP `http://otel-collector.tracing.svc.cluster.local:4318/v1/traces`。
- Produces:
  - Deployment `otel-collector`，1 副本。
  - Service `otel-collector`，端口 `4317`、`4318`。
  - health_check `:13133`，仅用于 Pod 探针。

- [ ] **Step 1: 创建 `infra/tracing/otel-collector.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tracing
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: tracing
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:
        check_interval: 5s
        limit_mib: 96
        spike_limit_mib: 32
      batch:
        timeout: 5s
        send_batch_size: 1024

    exporters:
      otlp:
        endpoint: tempo.tracing.svc.cluster.local:4317
        tls:
          insecure: true

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133

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
            - otlp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: tracing
  labels:
    app: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      nodeSelector:
        kubernetes.io/hostname: k8s-worker-1
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.163.2
          imagePullPolicy: IfNotPresent
          args:
            - --config=/etc/otelcol/config.yaml
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
            - name: health
              containerPort: 13133
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /
              port: health
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: health
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: config
              mountPath: /etc/otelcol
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: tracing
spec:
  type: ClusterIP
  selector:
    app: otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
    - name: otlp-http
      port: 4318
      targetPort: otlp-http
```

- [ ] **Step 2: 解释 YAML 后再应用**

重点解释：
- 为什么 Collector 只保留 `traces` pipeline，不复采集日志和指标。
- `memory_limiter` 的 `96 + 32 = 128 MiB` 和容器 limit 的关系。
- 为什么应用发 HTTP `4318`，Collector 发 Tempo 用 gRPC `4317`。
- `tls.insecure: true` 只用于集群内明文 gRPC，不是生产推荐。

校验：

```bash
kubectl apply --dry-run=client -f infra/tracing/otel-collector.yaml
kubectl apply -f infra/tracing/otel-collector.yaml
```

- [ ] **Step 3: 验证 Collector**

```bash
kubectl get deploy,pod,svc,endpoints -n tracing -o wide
kubectl logs -n tracing deploy/otel-collector --tail=80
```

Expected:
- `otel-collector` 为 `1/1 Running`。
- `Service` 的 endpoints 包含 Pod IP，端口 `4317/4318`。
- 日志出现 `Everything is ready. Begin running and processing data.` 或类似就绪信息。
- 没有 `failed to connect`、`connection refused`。

- [ ] **Step 4: 提交 Collector 配置**

```bash
git add infra/tracing/otel-collector.yaml
git commit -m "feat: add otel collector"
```

---

### Task 3: 给 demo 应用接入 OpenTelemetry

**Files:**
- Create: `infra/tracing/demo-service-otel.yaml`

**Interfaces:**
- Consumes:
  - `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://otel-collector.tracing.svc.cluster.local:4318/v1/traces`
  - `OTEL_SERVICE_NAME=log-demo`
- Produces:
  - 每次 HTTP 请求一个 trace，至少包含根 span `GET <path>` 和子 span。
  - JSON 日志新增 32 位 `trace_id`、16 位 `span_id`。
  - `/` 返回 200 和 info 日志；`/error` 返回 500、error 日志和 Python traceback。

- [ ] **Step 1: 创建 `infra/tracing/demo-service-otel.yaml`**

在 `data.app.py` 中写入下面的代码。注意 ConfigMap 里的 Python 代码必须保持 4 空格缩进。

```python
import atexit
import json
import logging
import os
import sys
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

from opentelemetry import propagate, trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(message)s",
)

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "log-demo")
OTLP_ENDPOINT = os.getenv(
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "http://otel-collector.tracing.svc.cluster.local:4318/v1/traces",
)

resource = Resource.create(
    {
        "service.name": SERVICE_NAME,
        "service.version": "1.0.0",
        "deployment.environment": "lab",
    }
)
provider = TracerProvider(resource=resource)
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT))
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)
atexit.register(provider.shutdown)


def current_ids():
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return "demo-trace-001", "demo-span-001"
    return (
        format(span_context.trace_id, "032x"),
        format(span_context.span_id, "016x"),
    )


def emit(level, message):
    trace_id, span_id = current_ids()
    logging.log(
        getattr(logging, level.upper()),
        json.dumps(
            {
                "ts": datetime.now(timezone.utc).isoformat(),
                "level": level,
                "service": SERVICE_NAME,
                "trace_id": trace_id,
                "span_id": span_id,
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
        path = urlparse(self.path).path
        carrier = {key.lower(): value for key, value in self.headers.items()}
        parent_context = propagate.extract(carrier)

        with tracer.start_as_current_span(
            f"GET {path}",
            context=parent_context,
            kind=trace.SpanKind.SERVER,
        ) as span:
            span.set_attribute("http.request.method", "GET")
            span.set_attribute("url.path", path)
            span.set_attribute("url.scheme", "http")

            if path == "/error":
                try:
                    with tracer.start_as_current_span("demo.fail") as child:
                        try:
                            raise RuntimeError("demo error for Loki")
                        except RuntimeError as exc:
                            child.record_exception(exc)
                            child.set_status(Status(StatusCode.ERROR, str(exc)))
                            span.set_status(Status(StatusCode.ERROR, str(exc)))
                            emit("error", "demo error for Loki")
                            traceback.print_exc()
                except Exception:
                    pass

                self._send(500, "error\n")
                span.set_attribute("http.response.status_code", 500)
                return

            with tracer.start_as_current_span("demo.hello"):
                emit("info", "hello from log-demo")

            self._send(200, "ok\n")
            span.set_attribute("http.response.status_code", 200)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
```

同一个 YAML 里的 Deployment 和 Service 用下面配置；资源名保持和阶段 3 一致，这样是原地更新，不会留下两个 demo。

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-demo-app
  namespace: demo
data:
  app.py: |
    # 把上面的 Python 代码粘贴到这里，整体缩进 4 空格
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
          command:
            - sh
            - -c
            - |
              pip install --no-cache-dir --disable-pip-version-check \
                opentelemetry-sdk==1.45.1 \
                opentelemetry-exporter-otlp-proto-http==1.45.1
              exec python -u /app/app.py
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PYTHONUNBUFFERED
              value: "1"
            - name: OTEL_SERVICE_NAME
              value: log-demo
            - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
              value: http://otel-collector.tracing.svc.cluster.local:4318/v1/traces
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 300m
              memory: 384Mi
          startupProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
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

- [ ] **Step 2: 解释 YAML 后再应用**

重点解释：
- 为什么用 `pip install` 启动安装，以及它的网络依赖。
- `BatchSpanProcessor` 的批量导出和 5 秒左右的可见延迟。
- `trace_id`/`span_id` 如何从当前 span 取出来写进日志。
- `startupProbe` 为什么给 150 秒，`readinessProbe` 为什么可以更早开始。
- `/error` 为什么同时设置 span status、记录 exception、输出 traceback。

校验：

```bash
kubectl apply --dry-run=client -f infra/tracing/demo-service-otel.yaml
kubectl apply -f infra/tracing/demo-service-otel.yaml
kubectl rollout restart deployment/log-demo -n demo
kubectl rollout status deployment/log-demo -n demo --timeout=5m
```

Expected:
- rollout 成功，Pod `1/1 Running`。
- 如果 Pod 卡在 `Init`/`0/1`，先看 `kubectl logs`，大概率是 `pip install` 网络或版本问题。

- [ ] **Step 3: 验证日志里的 trace_id 和 span_id**

```bash
kubectl exec -n demo deploy/log-demo -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/").read().decode().strip())'

kubectl logs -n demo deploy/log-demo --tail=20
```

Expected:
- 请求返回 `ok`。
- 日志是 JSON，包含 `"level": "info"`、`"trace_id": "<32位十六进制>"`、`"span_id": "<16位十六进制>"`。
- 如果仍是 `demo-trace-001`，说明当前 span 没有生效；不要继续做 Grafana 关联。

- [ ] **Step 4: 验证 Tempo 已经收到 trace**

```bash
kubectl exec -n demo deploy/log-demo -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://tempo.tracing.svc.cluster.local:3200/api/search?tags=service.name%3Dlog-demo&limit=5").read().decode())'
```

Expected:
- 返回 JSON，`traces` 数组非空，里面有 `traceID`。
- 如果为空，等 5 秒再查一次；仍为空就查 `kubectl logs -n tracing deploy/otel-collector` 和 `kubectl logs -n tracing tempo-0`。

- [ ] **Step 5: 提交 demo 变更**

```bash
git add infra/tracing/demo-service-otel.yaml
git commit -m "feat: instrument demo service with opentelemetry"
```

---

### Task 4: 配置 Grafana 的 Tempo 数据源和日志跳转

**Files:**
- Modify: `infra/logging/grafana-loki-datasource.yaml`
- Create: `infra/tracing/grafana-tempo-datasource.yaml`

**Interfaces:**
- Consumes: Loki UID `loki`、Tempo UID `tempo`、Tempo HTTP `:3200`。
- Produces:
  - Loki 日志行的 `TraceID` 链接，点击打开 Tempo。
  - Tempo trace 页的 “Logs for this span” 链接，点击打开 Loki。
  - 两边都通过嵌套 JSON 的 `trace_id` 关联。

- [ ] **Step 1: 修改 `infra/logging/grafana-loki-datasource.yaml`**

在 `jsonData` 下增加 `derivedFields`：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: monitoring
  labels:
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
          derivedFields:
            - name: TraceID
              matcherType: regex
              matcherRegex: 'trace_id[^a-f0-9]*([a-f0-9]{32})'
              datasourceUid: tempo
              url: '$${__value.raw}'
              urlDisplayLabel: 'View trace'
              targetBlank: true
```

- [ ] **Step 2: 创建 `infra/tracing/grafana-tempo-datasource.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  tempo-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Tempo
        uid: tempo
        type: tempo
        access: proxy
        url: http://tempo.tracing.svc.cluster.local:3200
        isDefault: false
        editable: false
        jsonData:
          nodeGraph:
            enabled: true
          tracesToLogsV2:
            datasourceUid: loki
            spanStartTimeShift: '-5m'
            spanEndTimeShift: '5m'
            customQuery: true
            query: '{namespace="demo", pod=~"log-demo-.*"} | json | line_format "{{.log}}" | json | trace_id="$${__trace.traceId}"'
            tags:
              - key: 'service.name'
                value: 'service'
              - key: 'k8s.namespace.name'
                value: 'namespace'
              - key: 'k8s.pod.name'
                value: 'pod'
```

- [ ] **Step 3: 解释 YAML 并做正则验证**

重点解释：
- `derivedFields` 是 Loki 日志到 Tempo 的入口；`datasourceUid: tempo` 必须和 Tempo 数据源 UID 一致。
- `$${__value.raw}` 为什么写成两个美元符号。
- `tracesToLogsV2.customQuery` 为什么要先 `line_format` 再 `json`：Loki 行外层是 `_p/log`，内层才是应用 JSON。
- `${__trace.traceId}` 是 Tempo 当前 trace 的 ID。

正则验证：

```bash
python3 - <<'PY'
import re
line = '{"_p":"F","log":"{\\"trace_id\\": \\"0123456789abcdef0123456789abcdef\\"}"}'
match = re.search(r'trace_id[^a-f0-9]*([a-f0-9]{32})', line)
print(match.group(1) if match else "NO MATCH")
PY
```

Expected: 输出 `0123456789abcdef0123456789abcdef`。

- [ ] **Step 4: 应用并重启 Grafana**

```bash
kubectl apply --dry-run=client -f infra/logging/grafana-loki-datasource.yaml
kubectl apply --dry-run=client -f infra/tracing/grafana-tempo-datasource.yaml
kubectl apply -f infra/logging/grafana-loki-datasource.yaml
kubectl apply -f infra/tracing/grafana-tempo-datasource.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n monitoring
kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=5m
```

Expected:
- 两个 ConfigMap 都创建/更新成功。
- Grafana rollout 成功。
- `kubectl get configmap -n monitoring | grep -E 'loki-datasource|tempo-datasource'` 能看到两个 ConfigMap。

- [ ] **Step 5: 在 Grafana UI 验证数据源**

打开 `http://172.25.254.10:30030`，确认：
- Connections → Data sources 里有 `Loki` 和 `Tempo`，没有重复的旧手工人数据源。
- `Tempo` 的 URL 是 `http://tempo.tracing.svc.cluster.local:3200`。
- `Loki` 的 derived field 里有 `TraceID`，指向 `Tempo`。

不记录或截图任何密码。

- [ ] **Step 6: 提交 Grafana 配置**

```bash
git add infra/logging/grafana-loki-datasource.yaml infra/tracing/grafana-tempo-datasource.yaml
git commit -m "feat: add tempo datasource and log trace links"
```

---

### Task 5: 端到端验收

**Files:**
- 无代码修改；结果写入 Task 6 的验收记录。

**Interfaces:**
- Consumes: Task 1-4 的 Tempo、Collector、demo、Grafana。
- Produces: 至少一次完整 trace，以及日志和 trace 双向跳转的证据。

- [ ] **Step 1: 生成 info 和 error 请求**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import urllib.error
import urllib.request

for _ in range(5):
    print(urllib.request.urlopen("http://127.0.0.1:8080/").read().decode().strip())

for _ in range(2):
    try:
        urllib.request.urlopen("http://127.0.0.1:8080/error")
    except urllib.error.HTTPError as exc:
        print("error", exc.code)
PY
```

Expected:
- 5 次 `ok`，2 次 `error 500`。
- 等待 5 秒，让 BatchSpanProcessor 导出。

- [ ] **Step 2: 确认 Loki 里同时有 info、error 和 trace_id**

在 Grafana Explore 的 Loki 查询：

```logql
{namespace="demo"}
  | json
  | line_format "{{.log}}"
  | json
```

Expected:
- 能看到 `level=info` 和 `level=error`。
- 每条都有 32 位 `trace_id`。
- error 记录仍带完整 Python traceback。
- 点开日志行的 `TraceID` 链接，应能跳到 Tempo。

- [ ] **Step 3: 在 Tempo 里确认 span 树**

在 Grafana Explore 选择 `Tempo`，用 TraceQL 或 Search：
- Service name: `log-demo`
- 找到刚才的 trace。

Expected:
- 根 span 名为 `GET /` 或 `GET /error`。
- `/` 的 trace 下有 `demo.hello` 子 span。
- `/error` 的 trace 下有 `demo.fail` 子 span，状态为 error。
- 点击 trace 页的 “Logs for this span”，能回到 Loki 并看到同一 `trace_id` 的日志。

- [ ] **Step 4: 用 API 交叉验证**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

url = "http://tempo.tracing.svc.cluster.local:3200/api/search?tags=service.name%3Dlog-demo&limit=5"
data = json.load(urllib.request.urlopen(url))
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
```

Expected:
- `traces` 数组非空。
- 每个 trace 有 `traceID`，并且和 Loki 日志里的 `trace_id` 能对上。

- [ ] **Step 5: 检查资源占用**

```bash
kubectl top pods -n tracing
kubectl top pods -n demo
kubectl top nodes
```

Expected:
- `tempo-0` 和 `otel-collector` 的实际内存低于 limits。
- 三个节点内存仍有至少 20% 余量。
- 如果 `k8s-server` 接近 80%，先停下来记录，不要直接加组件。

---

### Task 6: 文档、快照和推送

**Files:**
- Create: `docs/02-lab/04-phase-4-acceptance.md`
- Create: `docs/02-lab/05-tracing-values-explained.md`
- Create: `docs/03-qa/2026-10-23.md`
- Modify: `docs/03-qa/00-qa-log.md`
- Modify: `docs/README.md`
- Modify: `docs/02-lab/00-lab-design.md`
- Modify: `docs/02-lab/03-phase-3-acceptance.md`（把阶段 4 待做项更新为已完成）

**Interfaces:**
- Consumes: Task 1-5 的实际输出。
- Produces: 可复现的阶段 4 验收记录、YAML 解释、Q&A 和 `phase-4-tracing-ready` 快照。

- [ ] **Step 1: 写阶段 4 验收记录**

至少包含：
- 环境、chart/image 版本、命名空间。
- Tempo/Collector/demo/Grafana 的部署结果。
- 一次完整 trace 的 span 树截图文字描述（不记录密码）。
- Loki 日志里的 `trace_id` 和 Tempo trace ID 对应关系。
- Grafana 双向跳转结果。
- 资源占用。
- 偏差和未完成项。

- [ ] **Step 2: 写 YAML/values 解释文档**

`docs/02-lab/05-tracing-values-explained.md` 至少解释：
- 为什么 Tempo 用单机文件系统，不用 S3/MinIO。
- `tempo.retention`、PVC、`nodeSelector`。
- Collector 的 `receivers/processors/exporters/service.pipelines`。
- OTLP HTTP 与 OTLP gRPC 的区别。
- demo 的 SDK 初始化、BatchSpanProcessor、trace_id/span_id 注入。
- Loki derived field 和 Tempo `tracesToLogsV2` 的嵌套 JSON 查询。
- 为什么 `trace_id` 不做 Loki label。

- [ ] **Step 3: 更新 Q&A 和索引**

`docs/03-qa/2026-10-23.md` 记录当天实际命令、输出、错误和修复；`docs/03-qa/00-qa-log.md` 增加一行索引。

- [ ] **Step 4: 更新 README 和实验设计**

- `docs/README.md` 的 M4 行标记为已完成，并加入验收记录链接。
- `docs/02-lab/00-lab-design.md` 的阶段 4 增加状态和验收链接。
- 阶段 3 验收记录中的“进入阶段 4”改为“阶段 4 已完成”。

- [ ] **Step 5: 打快照**

三台 VM 干净关机：

```bash
shutdown -h now
```

在 VMware 中分别创建快照：

```text
phase-4-tracing-ready
```

开机后确认：

```bash
kubectl get nodes
kubectl get pods -n tracing
kubectl get pods -n demo
kubectl get pods -n logging
```

Expected:
- 三节点 `Ready`。
- `tempo-0`、`otel-collector`、`log-demo`、Loki、Fluent Bit 全部 Running。
- Grafana 和 Prometheus 正常。
- 快照创建后，再执行一次 Grafana 日志到 trace 的跳转检查。

- [ ] **Step 6: 提交并推送**

```bash
git add docs infra/tracing infra/logging/grafana-loki-datasource.yaml
git commit -m "docs: add phase 4 tracing acceptance"
git -c http.proxy= -c https.proxy= push
```

Expected:
- 本地和 `origin/feat/k8s-lab-bootstrap` 同步。
- 如果代理恢复，也可以直接 `git push`；不要修改全局代理配置。

---

## 回滚

如果阶段 4 失败并需要回到阶段 3：

```bash
helm uninstall tempo -n tracing
kubectl delete -f infra/tracing/otel-collector.yaml
kubectl apply -f infra/logging/demo-service.yaml
kubectl rollout restart deployment/log-demo -n demo
kubectl delete -f infra/tracing/grafana-tempo-datasource.yaml
kubectl apply -f infra/logging/grafana-loki-datasource.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n monitoring
```

如果只是 Grafana 数据源有问题，不要卸载 Tempo；先修 ConfigMap 和 Grafana rollout。

## 完成标准

- [ ] Tempo `tempo-0` 为 `1/1 Running`，PVC `Bound`。
- [ ] Collector `otel-collector` 为 `1/1 Running`，Tempo 能收到 OTLP。
- [ ] `log-demo` 日志带 32 位 `trace_id` 和 16 位 `span_id`。
- [ ] Tempo 能看到一次请求的完整 span 树。
- [ ] Loki 日志能跳到 Tempo，Tempo 能反查 Loki。
- [ ] 阶段 3 的日志查询和 traceback 多行合并仍然正常。
- [ ] 资源占用在 16 GB 实验环境可接受。
- [ ] 验收记录、YAML 解释、Q&A 已提交并推送。
- [ ] 三台 VM 有 `phase-4-tracing-ready` 快照。
