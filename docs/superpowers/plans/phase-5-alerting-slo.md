# 阶段 5 告警与 SLO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 `log-demo` 建立可计算的可用性 SLI/SLO，用多窗口燃烧率规则触发告警，并让告警经过 Alertmanager 的路由、分组、抑制、静默，最终送到本地 webhook。

**Architecture:** demo 增加 `/metrics`，Prometheus 通过 `ServiceMonitor` 抓取；`PrometheusRule` 计算 5m/1h/30m/6h 的可用性比例和燃烧率；`AlertmanagerConfig` 把 critical/warning 路由到同一个本地 webhook 服务的不同路径；用一个低速率 `busybox` loadgen 制造持续流量，故障注入时把目标路径切到 `/error`。

**Tech Stack:** k3s、kube-prometheus-stack 92.11.0（Prometheus Operator、Prometheus、Alertmanager、Grafana）、PromQL、PrometheusRule、ServiceMonitor、AlertmanagerConfig、Python 标准库、BusyBox。

**Spec:** `docs/02-lab/00-lab-design.md` 的阶段 5「告警与 SLO」。

## Global Constraints

- 集群仍是三节点 k3s：`k8s-server`、`k8s-worker-1`、`k8s-worker-2`；不新增重型后端。
- 现有 release：`kube-prometheus-stack`，命名空间 `monitoring`，chart `92.11.0`。
- Alertmanager CR：`kube-prometheus-stack-alertmanager`；Service：`kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093`；NodePort `30093`。
- Prometheus CR：`kube-prometheus-stack-prometheus`；Service：`kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`；NodePort `30090`。
- 现有 `ruleSelector`、`serviceMonitorSelector`、`alertmanagerConfigSelector` 都是 `{}`，会选中所有同命名空间/所有命名空间的对应 CR；不需要改 Helm values。
- SLO：`99.0%` 可用性，窗口 `7d`；错误预算 `1%`。
- Fast burn：`5m` 和 `1h` 都超过 `14.4x`，持续 `2m`，`severity=critical`。
- Slow burn：`30m` 和 `6h` 都超过 `6x`，持续 `15m`，`severity=warning`。
- 成功请求定义为 HTTP `2xx`/`3xx`；demo 当前只有 `200` 和 `500`。
- 指标标签保持低基数：`method`、规范化后的 `path`、`status`；不要把 `trace_id`、原始 URL 或用户输入做标签。
- `/metrics` 和 `/healthz` 不创建 span、不写日志、不计入业务请求指标。
- 所有命令在 `k8s-server` 上以 `root` 执行，不使用 `sudo`。
- 每个 Task 完成后立刻在 `docs/03-qa/2026-10-23.md` 追加实际命令、输出和结论，并同步 `docs/03-qa/00-qa-log.md`；Task 6 只做整理和最终索引，不把记录拖到阶段末尾。
- 不记录 Grafana/Alertmanager 密码、token、私钥；本阶段 Alertmanager 没有鉴权，只在本机实验网使用。
- 不提交 `infra/tracing/tempo-3.2.1.tgz` 和根目录 `部署k3s.md`。
- 验收后创建三台 VM 的 `phase-5-alerting-ready` 快照。

### 文件同步约定

仓库在 Windows 的 `E:\learn_aiops_sre`；集群命令在 `k8s-server` 上执行。每个新文件先用 PowerShell 传到 server：

```powershell
# 在 Windows PowerShell 执行
ssh root@172.25.254.10 "mkdir -p /root/alerting"
scp E:\learn_aiops_sre\infra\alerting\*.yaml root@172.25.254.10:/root/alerting/
scp E:\learn_aiops_sre\infra\tracing\demo-service-otel.yaml root@172.25.254.10:/root/tracing/
```

如果不想用 `scp`，也可以把 YAML 直接通过 `kubectl apply -f - <<'YAML' ... YAML` 送进集群；本计划默认使用 `/root/alerting/` 和 `/root/tracing/` 路径。

## Review Focus

- `/metrics` 被 Prometheus 每 15 秒抓取一次；如果它进入 trace/log 逻辑，会持续污染 Tempo 和 Loki。Task 1 必须验证 `/metrics` 不产生日志/trace。
- `path` 标签如果直接使用原始 URL，会出现高基数；Task 1 必须把未知路径归一化为 `other`。
- 没有流量时比例是 NaN/无数据，不等于 0% 错误；Task 2/3 必须验证 loadgen 停止时不会误报 fast burn，并由 `DemoNoTraffic` 单独提示。
- AlertmanagerConfig 会与默认的 `null` 路由和默认抑制规则合并；Task 5 必须检查生成后的完整配置，而不是只看 CR。
- 抑制和静默会让“告警没送达”看起来像故障；Task 5 必须用合成告警分别验证路由、分组、抑制、静默，并在测试后清理。

---

## 文件结构

**修改：**

- `infra/tracing/demo-service-otel.yaml`：给 demo 增加 `prometheus-client`、`/metrics`、请求计数和延迟直方图；给 Service 加 `app: log-demo` 标签。
- `docs/README.md`：阶段 5 完成后更新阅读顺序和 M5 状态。
- `docs/02-lab/00-lab-design.md`：阶段 5 完成后标记验收状态。
- `docs/03-qa/2026-10-23.md`：当天 Q&A、命令和结果。
- `docs/03-qa/00-qa-log.md`：当天索引。

**新建：**

- `infra/alerting/demo-servicemonitor.yaml`：让 Prometheus 抓取 `demo/log-demo:8080/metrics`。
- `infra/alerting/demo-loadgen.yaml`：低速率持续请求 `/`，可通过环境变量切到 `/error`。
- `infra/alerting/demo-slo-rules.yaml`：可用性 recording rules 和 fast/slow burn 告警。
- `infra/alerting/alert-webhook.yaml`：本地 webhook 接收器（ConfigMap + Deployment + Service）。
- `infra/alerting/alertmanager-config.yaml`：AlertmanagerConfig（路由、分组、receivers、抑制）。
- `docs/02-lab/06-phase-5-acceptance.md`：阶段 5 验收记录。
- `docs/02-lab/07-alerting-values-explained.md`：YAML/PromQL/Alertmanager 配置逐段解释。

---

### Task 1: demo 暴露 Prometheus 指标

**Files:**
- Modify: `infra/tracing/demo-service-otel.yaml`
- Test: 通过 `kubectl exec` 访问 `/metrics`，并用 Prometheus 文本格式检查指标。

**Interfaces:**
- Consumes: 现有 `log-demo` Deployment/Service、`python:3.12-slim`、OTel 初始化。
- Produces:
  - `demo_http_requests_total{method,path,status}` Counter
  - `demo_http_request_duration_seconds_bucket{method,path,le}` Histogram
  - `/metrics` 文本端点
  - Service 标签 `app: log-demo`

- [x] **Step 1: 先确认当前没有 `/metrics`**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import sys
import urllib.error
import urllib.request

try:
    body = urllib.request.urlopen("http://127.0.0.1:8080/metrics").read().decode()
    print("status=200 body=", body[:80].replace("\n", "\\n"))
    if "demo_http_requests_total" in body:
        print("unexpected: demo metrics already exposed")
        sys.exit(0)
    print("RED: /metrics is not Prometheus metrics yet")
    sys.exit(1)
except urllib.error.HTTPError as exc:
    print("RED: /metrics missing, status", exc.code)
    sys.exit(1)
PY
```

Expected: `RED: /metrics is not Prometheus metrics yet`，命令以退出码 1 结束。当前 demo 的 catch-all 会把 `/metrics` 当成普通路径返回 `200 ok`，所以不能只看 HTTP 200。

- [x] **Step 2: 修改 `app.py` 的导入和指标定义**

在 `infra/tracing/demo-service-otel.yaml` 的 `app.py` 里增加：

```python
import time
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)
```

在 `logging.basicConfig(...)` 之后增加：

```python
REQUEST_COUNT = Counter(
    "demo_http_requests_total",
    "Total HTTP requests handled by log-demo.",
    ["method", "path", "status"],
)
REQUEST_DURATION = Histogram(
    "demo_http_request_duration_seconds",
    "HTTP request duration for log-demo.",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
```

- [x] **Step 3: 修改 `_send` 支持 Content-Type**

把 `_send` 改成：

```python
def _send(self, status, body, content_type="text/plain; charset=utf-8"):
    self.send_response(status)
    self.send_header("Content-Type", content_type)
    self.end_headers()
    self.wfile.write(body.encode("utf-8"))
```

- [x] **Step 4: 在 `do_GET` 里加 `/metrics` 和计时**

在 `path = urlparse(self.path).path` 之后、`/healthz` 之前增加：

```python
if path == "/metrics":
    self._send(200, generate_latest().decode("utf-8"), CONTENT_TYPE_LATEST)
    return
```

然后在 `/healthz` 判断之后、创建 span 之前增加：

```python
start = time.perf_counter()
status = 500
metric_path = path if path in ("/", "/error") else "other"
try:
```

把原来的请求处理逻辑整体放进 `try`，并在 `finally` 里记录指标：

```python
finally:
    REQUEST_DURATION.labels("GET", metric_path).observe(
        time.perf_counter() - start
    )
    REQUEST_COUNT.labels("GET", metric_path, str(status)).inc()
```

在 `/error` 分支的 `self._send(500, "error\n")` 前设置：

```python
status = 500
```

在正常分支的 `self._send(200, "ok\n")` 前设置：

```python
status = 200
```

注意：`/metrics` 和 `/healthz` 必须在 `start = time.perf_counter()` 之前 `return`，否则它们会被计入指标。

- [x] **Step 5: 增加 `prometheus-client` 依赖**

把 Deployment 的 `pip install` 改成：

```yaml
pip install --no-cache-dir --disable-pip-version-check \
  opentelemetry-sdk==1.45.1 \
  opentelemetry-exporter-otlp-proto-http==1.45.1 \
  prometheus-client==0.21.1
```

- [x] **Step 6: 给 Service 加标签**

在 `Service log-demo` 的 `metadata` 下增加：

```yaml
labels:
  app: log-demo
```

ServiceMonitor 通过这个标签选择 Service；没有它，Prometheus 不会抓取。

- [x] **Step 7: 应用并等待 rollout**

```bash
kubectl apply -f /root/tracing/demo-service-otel.yaml
kubectl rollout status deployment/log-demo -n demo --timeout=180s
kubectl get pods -n demo -l app=log-demo -o wide
```

Expected: rollout 成功，`log-demo` 为 `1/1 Running`。

- [x] **Step 8: 验证 `/metrics` 和业务计数**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import urllib.request

for _ in range(3):
    print(urllib.request.urlopen("http://127.0.0.1:8080/").read().decode().strip())

# 未知路径应该被归一化成 path="other"，避免高基数
urllib.request.urlopen("http://127.0.0.1:8080/random-path").read()

metrics = urllib.request.urlopen("http://127.0.0.1:8080/metrics").read().decode()
for line in metrics.splitlines():
    if line.startswith("demo_http_requests_total"):
        print(line)
PY
```

Expected: 包含类似：

```text
demo_http_requests_total{method="GET",path="/",status="200"} 3.0
demo_http_requests_total{method="GET",path="other",status="200"} 1.0
```

- [x] **Step 9: 验证探针和抓取不污染日志**

```bash
kubectl logs -n demo deploy/log-demo --tail=20
```

Expected: 只看到手动请求产生的 `hello from log-demo`，没有 `/healthz` 或 `/metrics` 的日志行。

再调用一次 `/metrics`，确认日志行数没有增加：

```bash
before=$(kubectl logs -n demo deploy/log-demo --since=1m | wc -l)
kubectl exec -n demo deploy/log-demo -- python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/metrics").read()'
sleep 2
after=$(kubectl logs -n demo deploy/log-demo --since=1m | wc -l)
echo "before=$before after=$after"
```

Expected: `before` 和 `after` 相同。

- [x] **Step 10: 提交**

```bash
git add infra/tracing/demo-service-otel.yaml
git commit -m "feat: expose demo prometheus metrics"
```

---

### Task 2: 配置抓取和持续流量

**Files:**
- Create: `infra/alerting/demo-servicemonitor.yaml`
- Create: `infra/alerting/demo-loadgen.yaml`

**Interfaces:**
- Consumes: Task 1 的 `/metrics` 和 Service 标签 `app: log-demo`。
- Produces:
  - Prometheus target：`namespace="demo"` 的 `log-demo` metrics。
  - `demo-loadgen` Deployment；环境变量 `TARGET_PATH`、`INTERVAL_SECONDS`。

- [x] **Step 1: 写 ServiceMonitor**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: log-demo
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - demo
  selector:
    matchLabels:
      app: log-demo
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
```

- [x] **Step 2: 写低速率 loadgen**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-loadgen
  namespace: demo
  labels:
    app: demo-loadgen
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-loadgen
  template:
    metadata:
      labels:
        app: demo-loadgen
    spec:
      nodeSelector:
        kubernetes.io/hostname: k8s-worker-1
      containers:
        - name: loadgen
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                wget -q -T 2 -O /dev/null \
                  "http://log-demo.demo.svc.cluster.local:8080${TARGET_PATH}" || true
                sleep "${INTERVAL_SECONDS}"
              done
          env:
            - name: TARGET_PATH
              value: "/"
            - name: INTERVAL_SECONDS
              value: "2"
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 50m
              memory: 32Mi
```

`INTERVAL_SECONDS=2` 是每秒约 0.5 个请求。这个速率足够算 5m 比例，又不会把 Loki/Tempo 写爆。

- [x] **Step 3: 应用并检查**

```bash
kubectl apply -f /root/alerting/demo-servicemonitor.yaml
kubectl apply -f /root/alerting/demo-loadgen.yaml
kubectl get servicemonitor -n monitoring log-demo
kubectl get deploy,pod -n demo -l app=demo-loadgen -o wide
```

Expected: ServiceMonitor 存在；loadgen Pod `1/1 Running`。

- [x] **Step 4: 等 Prometheus 抓取**

```bash
sleep 45
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.parse
import urllib.request

base = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"

def query(expr):
    url = base + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    data = json.load(urllib.request.urlopen(url))
    print(expr, "=>", data["data"]["result"])

query('up{namespace="demo"}')
query('up{job=~".*log-demo.*"}')
query('sum(rate(demo_http_requests_total[5m]))')
PY
```

Expected:

- `up{namespace="demo"}` 或 `up{job=~".*log-demo.*"}` 至少一个有结果，值为 `1`。
- `sum(rate(demo_http_requests_total[5m]))` 大于 `0`。

如果两个 `up` 都为空，先看 Prometheus `Status → Targets`，再检查 ServiceMonitor 的 `namespaceSelector` 和 Service 的 `app: log-demo` 标签。

- [x] **Step 5: 提交**

```bash
git add infra/alerting/demo-servicemonitor.yaml infra/alerting/demo-loadgen.yaml
git commit -m "feat: scrape demo metrics with load generator"
```

---

### Task 3: 定义 SLI/SLO 和多窗口燃烧率告警

**Files:**
- Create: `infra/alerting/demo-slo-rules.yaml`

**Interfaces:**
- Consumes: Task 2 的 `demo_http_requests_total`。
- Produces:
  - `demo:sli_availability:ratio_rate5m`
  - `demo:sli_availability:ratio_rate1h`
  - `demo:sli_availability:ratio_rate30m`
  - `demo:sli_availability:ratio_rate6h`
  - `demo:error_budget_burn_rate5m`
  - `demo:error_budget_burn_rate1h`
  - `demo:error_budget_burn_rate30m`
  - `demo:error_budget_burn_rate6h`
  - 告警 `DemoAvailabilityFastBurn`、`DemoAvailabilitySlowBurn`、`DemoNoTraffic`

- [x] **Step 1: 写 PrometheusRule**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: demo-slo
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: demo-slo-recording
      interval: 30s
      rules:
        - record: demo:sli_availability:ratio_rate5m
          expr: |
            (
              sum(rate(demo_http_requests_total{status=~"2..|3.."}[5m]))
              or
              vector(0)
            )
            /
            sum(rate(demo_http_requests_total[5m]))
        - record: demo:sli_availability:ratio_rate1h
          expr: |
            (
              sum(rate(demo_http_requests_total{status=~"2..|3.."}[1h]))
              or
              vector(0)
            )
            /
            sum(rate(demo_http_requests_total[1h]))
        - record: demo:sli_availability:ratio_rate30m
          expr: |
            (
              sum(rate(demo_http_requests_total{status=~"2..|3.."}[30m]))
              or
              vector(0)
            )
            /
            sum(rate(demo_http_requests_total[30m]))
        - record: demo:sli_availability:ratio_rate6h
          expr: |
            (
              sum(rate(demo_http_requests_total{status=~"2..|3.."}[6h]))
              or
              vector(0)
            )
            /
            sum(rate(demo_http_requests_total[6h]))
        - record: demo:error_budget_burn_rate5m
          expr: clamp_min(1 - demo:sli_availability:ratio_rate5m, 0) / 0.01
        - record: demo:error_budget_burn_rate1h
          expr: clamp_min(1 - demo:sli_availability:ratio_rate1h, 0) / 0.01
        - record: demo:error_budget_burn_rate30m
          expr: clamp_min(1 - demo:sli_availability:ratio_rate30m, 0) / 0.01
        - record: demo:error_budget_burn_rate6h
          expr: clamp_min(1 - demo:sli_availability:ratio_rate6h, 0) / 0.01
    - name: demo-slo-alerts
      interval: 30s
      rules:
        - alert: DemoAvailabilityFastBurn
          expr: |
            demo:error_budget_burn_rate5m > 14.4
            and
            demo:error_budget_burn_rate1h > 14.4
          for: 2m
          labels:
            severity: critical
            service: demo
            slo: availability
            namespace: monitoring
          annotations:
            summary: "demo 可用性快速燃烧（5m/1h）"
            description: "5m 和 1h 燃烧率都超过 14.4x；检查 /error、demo 日志和 trace。"
        - alert: DemoAvailabilitySlowBurn
          expr: |
            demo:error_budget_burn_rate30m > 6
            and
            demo:error_budget_burn_rate6h > 6
          for: 15m
          labels:
            severity: warning
            service: demo
            slo: availability
            namespace: monitoring
          annotations:
            summary: "demo 可用性慢速燃烧（30m/6h）"
            description: "30m 和 6h 燃烧率都超过 6x；错误在持续消耗 7d 错误预算。"
        - alert: DemoNoTraffic
          expr: |
            sum(rate(demo_http_requests_total[5m])) == 0
            or
            absent(sum(rate(demo_http_requests_total[5m])))
          for: 10m
          labels:
            severity: warning
            service: demo
            slo: availability
            namespace: monitoring
          annotations:
            summary: "demo 没有请求"
            description: "5m 内没有 demo 请求，SLI 无数据；检查 demo-loadgen 和 ServiceMonitor。"

```

- [x] **Step 2: 应用并确认规则被 Prometheus 加载**

```bash
kubectl apply -f /root/alerting/demo-slo-rules.yaml
kubectl get prometheusrule -n monitoring demo-slo
sleep 45
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.parse
import urllib.request

base = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"

def query(expr):
    url = base + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    data = json.load(urllib.request.urlopen(url))
    print(expr, "=>", data["data"]["result"])

query("demo:sli_availability:ratio_rate5m")
query("demo:error_budget_burn_rate5m")
PY
```

Expected:

- `demo:sli_availability:ratio_rate5m` 约为 `1`。
- `demo:error_budget_burn_rate5m` 约为 `0`。

- [x] **Step 3: 确认正常流量下没有 fast/slow burn 告警**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.parse
import urllib.request

url = (
    "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
    "/api/v1/query?"
    + urllib.parse.urlencode({
        "query": 'ALERTS{alertname=~"DemoAvailability(Fast|Slow)Burn"}'
    })
)
print(json.load(urllib.request.urlopen(url))["data"]["result"])
PY
```

Expected: `[]`。

- [x] **Step 4: 验证停流量不会误报 fast/slow burn**

```bash
kubectl scale deployment/demo-loadgen -n demo --replicas=0
sleep 360
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.parse
import urllib.request

url = (
    "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
    "/api/v1/query?"
    + urllib.parse.urlencode({
        "query": 'ALERTS{alertname=~"DemoAvailability(Fast|Slow)Burn"}'
    })
)
print(json.load(urllib.request.urlopen(url))["data"]["result"])
PY
kubectl scale deployment/demo-loadgen -n demo --replicas=1
```

Expected: 仍然是 `[]`。没有流量时 SLI 是无数据，不应被当成 100% 错误；`DemoNoTraffic` 会在 10 分钟后单独提示。

实际：6 分钟时 `DemoNoTraffic` 为 `pending`，因为 `for: 10m` 还没满足；fast/slow burn 为 `[]`。恢复 loadgen 后 60 秒，请求速率回到约 `0.5`，pending 消失。

- [x] **Step 5: 提交**

```bash
git add infra/alerting/demo-slo-rules.yaml
git commit -m "feat: add demo slo burn-rate alerts"
```

---

### Task 4: 本地 webhook 接收器

**Files:**
- Create: `infra/alerting/alert-webhook.yaml`

**Interfaces:**
- Consumes: 无。
- Produces:
  - Deployment/Service `alert-webhook.monitoring.svc.cluster.local:8080`
  - 路径 `/webhook/default`、`/webhook/critical`、`/webhook/warning`
  - 每个 POST 在日志里打印 `ts`、`path`、`payload`

- [x] **Step 1: 写 ConfigMap、Deployment、Service**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-webhook-app
  namespace: monitoring
data:
  webhook.py: |
    import json
    from datetime import datetime, timezone
    from http.server import BaseHTTPRequestHandler, HTTPServer


    class Handler(BaseHTTPRequestHandler):
        def _send(self, status, body):
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))

        def do_GET(self):
            if self.path == "/healthz":
                self._send(200, "ok\n")
            else:
                self._send(404, "not found\n")

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = {"raw": raw}

            print(
                json.dumps(
                    {
                        "ts": datetime.now(timezone.utc).isoformat(),
                        "path": self.path,
                        "payload": payload,
                    },
                    ensure_ascii=False,
                ),
                flush=True,
            )
            self._send(200, "ok\n")

        def log_message(self, fmt, *args):
            return


    if __name__ == "__main__":
        HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alert-webhook
  namespace: monitoring
  labels:
    app: alert-webhook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alert-webhook
  template:
    metadata:
      labels:
        app: alert-webhook
    spec:
      nodeSelector:
        kubernetes.io/hostname: k8s-worker-1
      containers:
        - name: webhook
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
          command:
            - python
            - -u
            - /app/webhook.py
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PYTHONUNBUFFERED
              value: "1"
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: alert-webhook-app
---
apiVersion: v1
kind: Service
metadata:
  name: alert-webhook
  namespace: monitoring
  labels:
    app: alert-webhook
spec:
  selector:
    app: alert-webhook
  ports:
    - name: http
      port: 8080
      targetPort: http
```

- [x] **Step 2: 应用并检查**

```bash
kubectl apply -f /root/alerting/alert-webhook.yaml
kubectl rollout status deployment/alert-webhook -n monitoring --timeout=120s
kubectl get pod,svc -n monitoring -l app=alert-webhook -o wide
```

Expected: Pod `1/1 Running`；Service `alert-webhook` 的 `8080/TCP`。

- [x] **Step 3: 测试健康检查和 POST**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

base = "http://alert-webhook.monitoring.svc.cluster.local:8080"

print("health:", urllib.request.urlopen(base + "/healthz").read().decode().strip())

body = json.dumps({"status": "firing", "alerts": [{"labels": {"alertname": "WebhookTest"}}]}).encode()
req = urllib.request.Request(
    base + "/webhook/test",
    data=body,
    headers={"Content-Type": "application/json"},
    method="POST",
)
print("post:", urllib.request.urlopen(req).read().decode().strip())
PY

kubectl logs -n monitoring deploy/alert-webhook --tail=5
```

Expected:

- `health: ok`
- `post: ok`
- 日志里有 `"path": "/webhook/test"` 和 `"alertname": "WebhookTest"`。

- [x] **Step 4: 提交**

```bash
git add infra/alerting/alert-webhook.yaml
git commit -m "feat: add local alert webhook receiver"
```

---

### Task 5: Alertmanager 路由、分组、抑制和静默

**Files:**
- Create: `infra/alerting/alertmanager-config.yaml`

**Interfaces:**
- Consumes: Task 3 的告警标签 `severity`、`service`、`slo`；Task 4 的 webhook URL。
- Produces:
  - AlertmanagerConfig `demo-alerting`
  - critical → `/webhook/critical`
  - warning → `/webhook/warning`
  - 其他 → `/webhook/default`
  - critical 抑制同 `service`/`slo` 的 warning

> 匹配前提：`AlertmanagerConfig` 默认 `alertmanagerConfigMatcherStrategy: OnNamespace`，只处理带 `namespace: monitoring` 标签的告警。因此 Task 3 的告警规则和这里的合成测试都必须带 `namespace: monitoring`。
>
> 测试隔离：critical 会抑制同 `service`/`slo` 的 warning。为了让“分组”和“静默”测试不被前面的 `TestCritical` 抑制，每个测试使用不同的 `service`：`test-routing`、`test-group`、`test-inhibit`、`test-silence`。

- [x] **Step 1: 写 AlertmanagerConfig**

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: demo-alerting
  namespace: monitoring
  labels:
    alertmanagerConfig: main
spec:
  route:
    receiver: webhook-default
    groupBy:
      - alertname
      - service
      - severity
    groupWait: 10s
    groupInterval: 30s
    repeatInterval: 1h
    routes:
      - receiver: webhook-critical
        matchers:
          - name: severity
            value: critical
            matchType: "="
        repeatInterval: 30m
      - receiver: webhook-warning
        matchers:
          - name: severity
            value: warning
            matchType: "="
        repeatInterval: 2h
  receivers:
    - name: webhook-default
      webhookConfigs:
        - url: http://alert-webhook.monitoring.svc.cluster.local:8080/webhook/default
          sendResolved: true
    - name: webhook-critical
      webhookConfigs:
        - url: http://alert-webhook.monitoring.svc.cluster.local:8080/webhook/critical
          sendResolved: true
    - name: webhook-warning
      webhookConfigs:
        - url: http://alert-webhook.monitoring.svc.cluster.local:8080/webhook/warning
          sendResolved: true
  inhibitRules:
    - sourceMatch:
        - name: severity
          value: critical
          matchType: "="
      targetMatch:
        - name: severity
          value: warning
          matchType: "="
      equal:
        - service
        - slo
```

- [x] **Step 2: 应用并等待 Operator 生成配置**

```bash
kubectl get crd alertmanagerconfigs.monitoring.coreos.com
kubectl get alertmanagerconfig -A

kubectl get alertmanager -n monitoring kube-prometheus-stack-alertmanager \
  -o jsonpath='{.spec.alertmanagerConfigSelector}{"\n"}{.spec.alertmanagerConfigNamespaceSelector}{"\n"}{.spec.alertmanagerConfigMatcherStrategy}{"\n"}'

kubectl apply -f /root/alerting/alertmanager-config.yaml
kubectl get alertmanagerconfig -n monitoring demo-alerting
sleep 30
kubectl get alertmanager -n monitoring kube-prometheus-stack-alertmanager
```

Expected: AlertmanagerConfig 存在；Alertmanager `RECONCILED=True`。

- [x] **Step 3: 检查生成后的 Alertmanager 配置**

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  zcat /etc/alertmanager/config/alertmanager.yaml.gz
```

Expected: 能看到：

- `receiver: webhook-default`
- `webhook-critical`、`webhook-warning`
- `group_by` 包含 `alertname`、`service`、`severity`
- `inhibit_rules` 包含 `source_matchers` critical 和 `target_matchers` warning

如果只看到默认的 `null` receiver，先看 Operator 日志：

```bash
kubectl logs -n monitoring deploy/kube-prometheus-stack-operator --tail=80
```

- [x] **Step 4: 测试 critical 路由**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

url = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts"
alerts = [{
    "labels": {
        "alertname": "TestCritical",
        "severity": "critical",
        "service": "test-routing",
        "slo": "test",
        "namespace": "monitoring",
        "instance": "test-1",
    },
    "annotations": {"summary": "synthetic critical"},
}]
req = urllib.request.Request(
    url,
    data=json.dumps(alerts).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(urllib.request.urlopen(req).status)
PY

sleep 15
kubectl logs -n monitoring deploy/alert-webhook --tail=10
```

Expected: webhook 日志里出现 `"path": "/webhook/critical"`，payload 的 `alertname` 是 `TestCritical`。

- [x] **Step 5: 测试 warning 路由和分组**

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

url = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts"
alerts = [
    {
        "labels": {
            "alertname": "TestGroup",
            "severity": "warning",
            "service": "test-group",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-a",
        },
        "annotations": {"summary": "group test a"},
    },
    {
        "labels": {
            "alertname": "TestGroup",
            "severity": "warning",
            "service": "test-group",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-b",
        },
        "annotations": {"summary": "group test b"},
    },
]
req = urllib.request.Request(
    url,
    data=json.dumps(alerts).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(urllib.request.urlopen(req).status)
PY

sleep 15
kubectl logs -n monitoring deploy/alert-webhook --tail=15
```

Expected:

- 出现 `"path": "/webhook/warning"`。
- 同一个 webhook payload 的 `alerts` 数组里有 2 条 `TestGroup`，因为 `instance` 不在 `groupBy` 里。

- [x] **Step 6: 测试抑制**

同时发 critical 和 warning，二者 `service`、`slo` 相同：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

url = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts"
alerts = [
    {
        "labels": {
            "alertname": "TestInhibitCritical",
            "severity": "critical",
            "service": "test-inhibit",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-1",
        },
        "annotations": {"summary": "inhibit source"},
    },
    {
        "labels": {
            "alertname": "TestInhibitWarning",
            "severity": "warning",
            "service": "test-inhibit",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-1",
        },
        "annotations": {"summary": "should be inhibited"},
    },
]
req = urllib.request.Request(
    url,
    data=json.dumps(alerts).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(urllib.request.urlopen(req).status)
PY

sleep 20
kubectl logs -n monitoring deploy/alert-webhook --tail=20
```

Expected:

- 看到 `TestInhibitCritical` 走 `/webhook/critical`。
- 看不到 `TestInhibitWarning` 的 firing 通知；它被 critical 抑制。

- [x] **Step 7: 测试静默**

先创建 10 分钟静默：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request
from datetime import datetime, timedelta, timezone

base = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
now = datetime.now(timezone.utc)
body = {
    "matchers": [
        {"name": "alertname", "value": "TestSilence", "isRegex": False, "isEqual": True}
    ],
    "startsAt": now.isoformat(),
    "endsAt": (now + timedelta(minutes=10)).isoformat(),
    "createdBy": "lab",
    "comment": "phase 5 silence test",
}
req = urllib.request.Request(
    base + "/api/v2/silences",
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(json.load(urllib.request.urlopen(req))["silenceID"])
PY
```

把输出的 silence ID 记下来，然后发一条 `TestSilence`：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

url = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts"
alerts = [{
    "labels": {
        "alertname": "TestSilence",
        "severity": "warning",
        "service": "test-silence",
        "slo": "test",
        "namespace": "monitoring",
        "instance": "test-1",
    },
    "annotations": {"summary": "should be silenced"},
}]
req = urllib.request.Request(
    url,
    data=json.dumps(alerts).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(urllib.request.urlopen(req).status)
PY

sleep 15
kubectl logs -n monitoring deploy/alert-webhook --tail=10
```

Expected: 没有 `TestSilence` 的 firing 通知。

删除静默（把 `<SILENCE_ID>` 换成上一步输出）：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import urllib.request

silence_id = "<SILENCE_ID>"
url = (
    "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
    f"/api/v2/silence/{silence_id}"
)
req = urllib.request.Request(url, method="DELETE")
print(urllib.request.urlopen(req).status)
PY
```

Expected: `200`。

- [x] **Step 8: 清理合成告警**

给合成告警发一个已过期的 `endsAt`，让它们进入 resolved：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request
from datetime import datetime, timedelta, timezone

url = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts"
past = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
alerts = [
    {
        "labels": {
            "alertname": "TestCritical",
            "severity": "critical",
            "service": "test-routing",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-1",
        },
        "endsAt": past,
    },
    {
        "labels": {
            "alertname": "TestGroup",
            "severity": "warning",
            "service": "test-group",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-a",
        },
        "endsAt": past,
    },
    {
        "labels": {
            "alertname": "TestGroup",
            "severity": "warning",
            "service": "test-group",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-b",
        },
        "endsAt": past,
    },
    {
        "labels": {
            "alertname": "TestInhibitCritical",
            "severity": "critical",
            "service": "test-inhibit",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-1",
        },
        "endsAt": past,
    },
    {
        "labels": {
            "alertname": "TestInhibitWarning",
            "severity": "warning",
            "service": "test-inhibit",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-1",
        },
        "endsAt": past,
    },
    {
        "labels": {
            "alertname": "TestSilence",
            "severity": "warning",
            "service": "test-silence",
            "slo": "test",
            "namespace": "monitoring",
            "instance": "test-1",
        },
        "endsAt": past,
    },
]
req = urllib.request.Request(
    url,
    data=json.dumps(alerts).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(urllib.request.urlopen(req).status)
PY
```

- [x] **Step 9: 真实故障注入，验证规则到通知**

先确认正常流量下没有 fast burn，然后把 loadgen 切到 `/error`：

```bash
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/error
kubectl rollout status deployment/demo-loadgen -n demo --timeout=120s
```

等待约 12–15 分钟（因为 fast burn 要求 5m 和 1h 两个窗口都超过 14.4x；1h 窗口需要累计约 9 分钟以上的全错误流量，再加 2 分钟 `for`）：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.parse
import urllib.request

base = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
for expr in [
    "demo:error_budget_burn_rate5m",
    "demo:error_budget_burn_rate1h",
    'ALERTS{alertname="DemoAvailabilityFastBurn"}',
]:
    url = base + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    data = json.load(urllib.request.urlopen(url))
    print(expr, "=>", data["data"]["result"])
PY
```

Expected: 最终 `ALERTS` 出现 `DemoAvailabilityFastBurn`，`alertstate="firing"`。

检查 Alertmanager 和 webhook：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

url = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts"
data = json.load(urllib.request.urlopen(url))
for alert in data:
    labels = alert["labels"]
    if labels.get("alertname") == "DemoAvailabilityFastBurn":
        print(labels, alert["status"])
PY

kubectl logs -n monitoring deploy/alert-webhook --tail=20
```

Expected: webhook 日志出现 `/webhook/critical` 和 `DemoAvailabilityFastBurn`。

恢复流量：

```bash
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/
kubectl rollout status deployment/demo-loadgen -n demo --timeout=120s
```

等待几分钟，确认告警 resolved，webhook 收到 `"status": "resolved"`。

实际：FastBurn 于 `13:22:09` resolved，webhook 收到 `/webhook/critical` 的 `"status": "resolved"`。但 `DemoAvailabilitySlowBurn` 于 `13:20:09` firing，因为 30m/6h 窗口仍保留故障期 500s；它需要接近 6 小时才能自然稀释。本实验没有等待 SlowBurn resolved，记录为已知偏差，不通过改阈值或伪造状态来掩盖。

- [x] **Step 10: 提交**

```bash
git add infra/alerting/alertmanager-config.yaml
git commit -m "feat: route demo alerts through alertmanager"
```

---

### Task 6: 验收文档、Q&A、快照和推送

**Files:**
- Create: `docs/02-lab/06-phase-5-acceptance.md`
- Create: `docs/02-lab/07-alerting-values-explained.md`
- Modify: `docs/README.md`
- Modify: `docs/02-lab/00-lab-design.md`
- Modify: `docs/03-qa/2026-10-23.md`
- Modify: `docs/03-qa/00-qa-log.md`

**Interfaces:**
- Consumes: Task 1-5 的实际输出。
- Produces: 可复现的阶段 5 验收记录、YAML/PromQL 解释、Q&A 和 `phase-5-alerting-ready` 快照。

- [x] **Step 1: 写验收记录**

至少包含：

- 环境、chart 版本、命名空间。
- SLI/SLO 定义、错误预算、为什么用 7d。
- 5m/1h/30m/6h 四个窗口和 14.4x/6x 阈值。
- `demo_http_requests_total` 和 `/metrics` 的实际输出。
- Prometheus target `up{namespace="demo"}` 的结果。
- 正常流量、错误注入、fast burn firing、webhook critical、恢复 resolved 的时间线。
- 路由、分组、抑制、静默四个测试的实际结果。
- 资源占用（loadgen、webhook、Prometheus 规则评估开销）。
- 偏差和未完成项（slow burn 没有真实跑满 6h 等）。
- 快照结果。

- [x] **Step 2: 写 YAML/PromQL 解释文档**

`docs/02-lab/07-alerting-values-explained.md` 至少解释：

- 为什么先加 `/metrics`，而不是直接用 kube-state-metrics 推断业务成功率。
- `Counter`、`Histogram`、`rate()`、`histogram_quantile()` 的关系。
- 为什么 `path` 要归一化，为什么 `trace_id` 不能做标签。
- 99% SLO、7d 错误预算、burn rate 的公式。
- 为什么 fast burn 要同时看 5m 和 1h，slow burn 要同时看 30m 和 6h。
- `PrometheusRule` 的 `record` 和 `alert` 两类规则。
- `ServiceMonitor` 如何通过 Service 标签找到 demo。
- `AlertmanagerConfig` 的 `route`、`groupBy`、`receivers`、`inhibitRules`。
- 为什么 critical 能抑制 warning，`equal` 为什么是 `service`/`slo`。
- 静默和抑制的区别：抑制是规则自动做，静默是人手动设。
- 常见错误：`up=0`、指标无数据、Alertmanager 配置没合并、webhook 503、静默忘记删除。

- [x] **Step 3: 更新 Q&A 和索引**

在 `docs/03-qa/2026-10-23.md` 增加当天问题，例如：

- 为什么 `/metrics` 不能走 trace 逻辑？
- 为什么 99% SLO 的 burn rate 分母是 0.01？
- 为什么 fast burn 要两个窗口？
- AlertmanagerConfig 和直接改 `alertmanager.yaml` 有什么区别？
- 抑制和静默分别在什么场景用？
- 为什么 loadgen 只跑 0.5 rps？

更新 `docs/03-qa/00-qa-log.md` 当天索引。

- [x] **Step 4: 更新 README 和实验设计**

- `docs/README.md`：阅读顺序加入阶段 5 验收记录和 YAML 解释；M5 标记完成并链接。
- `docs/02-lab/00-lab-design.md`：阶段 5 加状态、验收记录链接和快照说明。

- [x] **Step 5: 检查资源**

```bash
kubectl top pods -n demo
kubectl top pods -n monitoring
kubectl top nodes
```

Expected: 新增 `demo-loadgen`、`alert-webhook` 都是小内存；节点内存没有接近 80%。

- [x] **Step 6: 创建快照**

按阶段 4 的方式：

1. 三台 VM 干净关机（worker 先，server 后）。
2. VMware 分别创建 `phase-5-alerting-ready` 快照。
3. 开机后确认三节点 Ready，`monitoring`、`demo`、`logging`、`tracing` 的 Pod 正常。
4. 确认 Alertmanager UI `http://172.25.254.10:30093` 能看到配置，webhook 仍能收到测试告警。

- [x] **Step 7: 提交并推送**

```bash
git add docs/README.md docs/02-lab/00-lab-design.md \
  docs/02-lab/06-phase-5-acceptance.md docs/02-lab/07-alerting-values-explained.md \
  docs/03-qa/00-qa-log.md docs/03-qa/2026-10-23.md \
  docs/superpowers/plans/phase-5-alerting-slo.md
git commit -m "docs: add phase 5 alerting and slo acceptance"
git -c http.proxy= -c https.proxy= push
```

不要 `git add infra/tracing/tempo-3.2.1.tgz` 或根目录 `部署k3s.md`。

---

## 完成标准

- [x] `demo` 的 `/metrics` 返回 `demo_http_requests_total` 和延迟直方图。
- [x] `/metrics`、`/healthz` 不产生日志和 trace。
- [x] Prometheus target `up{namespace="demo"}` 为 `1`。
- [x] 正常流量下 `demo:sli_availability:ratio_rate5m` 约为 `1`，burn rate 约为 `0`。
- [x] `DemoAvailabilityFastBurn` 在错误注入后进入 firing，Alertmanager 路由到 `/webhook/critical`。
- [x] 恢复流量后告警 resolved，webhook 收到 resolved。
- [x] 合成告警验证了 critical/warning 路由、同组聚合、critical 抑制 warning、静默阻止通知。
- [x] 静默测试后已删除，合成告警已清理。
- [x] 验收记录、YAML 解释、Q&A 已提交并推送。
- [x] 三台 VM 有 `phase-5-alerting-ready` 快照。
