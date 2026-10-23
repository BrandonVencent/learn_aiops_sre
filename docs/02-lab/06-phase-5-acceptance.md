# 阶段 5 告警与 SLO 验收记录

> 状态：验收通过，存在一项已知偏差（SlowBurn 长窗口未等待自然恢复）；三台 VM 已创建 `phase-5-alerting-ready` 快照。
> 本记录只写配置、命令和验证结果，不记录 Grafana 密码、token 或私钥。

## 环境

| 项 | 值 |
|---|---|
| 宿主机 | Windows，16 GB 内存，14 核 20 线程 |
| VMware 网络 | `VMnet8`，`172.25.254.0/24`，网关 `172.25.254.2` |
| `k8s-server` | `172.25.254.10/24`，6 GB 内存 |
| `k8s-worker-1` | `172.25.254.11/24`，3 GB 内存 |
| `k8s-worker-2` | `172.25.254.12/24`，3 GB 内存 |
| 系统 | Ubuntu Server 22.04.5 LTS |
| 集群 | k3s `v1.36.5+k3s1` |
| 监控 chart | `kube-prometheus-stack-92.11.0` |
| Alertmanager | `v0.34.1` |
| 监控命名空间 | `monitoring` |
| demo 命名空间 | `demo` |
| demo 镜像 | 自带 Python 应用，使用 `prometheus-client` |
| loadgen | `busybox:1.36` |
| webhook | `python:3.12-slim` |
| AlertmanagerConfig | [`infra/alerting/alertmanager-config.yaml`](../../infra/alerting/alertmanager-config.yaml) |
| SLO 规则 | [`infra/alerting/demo-slo-rules.yaml`](../../infra/alerting/demo-slo-rules.yaml) |
| ServiceMonitor | [`infra/alerting/demo-servicemonitor.yaml`](../../infra/alerting/demo-servicemonitor.yaml) |
| loadgen 清单 | [`infra/alerting/demo-loadgen.yaml`](../../infra/alerting/demo-loadgen.yaml) |
| webhook 清单 | [`infra/alerting/alert-webhook.yaml`](../../infra/alerting/alert-webhook.yaml) |
| demo 指标/trace 清单 | [`infra/tracing/demo-service-otel.yaml`](../../infra/tracing/demo-service-otel.yaml) |

## 验收清单

- [x] demo `/metrics` 返回 `demo_http_requests_total` 和请求延迟直方图
- [x] `/metrics`、`/healthz` 不写业务日志，也不创建 trace
- [x] ServiceMonitor `log-demo` 选中 demo Service
- [x] Prometheus target `up{namespace="demo"}=1`
- [x] loadgen 以约 `0.5 req/s` 持续请求 demo
- [x] 正常流量下 `demo:sli_availability:ratio_rate5m≈1`，burn rate `≈0`
- [x] `DemoAvailabilityFastBurn` 在真实 `/error` 注入后 firing
- [x] Alertmanager 将 critical 路由到 `/webhook/critical`
- [x] 恢复流量后 FastBurn resolved，webhook 收到 `"status": "resolved"`
- [x] 合成告警验证 critical 路由、warning 路由和默认路由
- [x] 合成告警验证同组 warning 合并为一个 webhook payload
- [x] 合成告警验证 critical 抑制同 `service`/`slo` 的 warning
- [x] 创建静默后 `TestSilence` 被抑制，删除静默成功
- [x] 合成告警已清理
- [x] SlowBurn 长窗口行为已记录为已知偏差
- [x] 重启后三节点 `Ready`，各命名空间 Pod 全部 `Running`
- [x] 重启后 Alertmanager UI 正常，webhook 测试仍返回 200
- [x] 三台 VM 已创建 `phase-5-alerting-ready` 快照

## 1. 数据流

```text
loadgen
  |
  | GET / 或 /error
  v
log-demo Service :8080
  |
  v
demo Pod /metrics
  |
  | 每 15 秒抓取
  v
Prometheus
  |
  | 每 30 秒评估 PrometheusRule
  v
ALERTS
  |
  v
Alertmanager
  |
  +-- severity=critical -> /webhook/critical
  +-- severity=warning  -> /webhook/warning
  +-- 其他              -> /webhook/default
                              |
                              v
                       alert-webhook Pod
                              |
                              v
                         kubectl logs
```

对应的 Kubernetes 对象：

```text
ServiceMonitor/log-demo
  -> Prometheus target

PrometheusRule/demo-slo
  -> SLI recording rules
  -> FastBurn / SlowBurn / NoTraffic alerts

AlertmanagerConfig/demo-alerting
  -> route / groupBy / receivers / inhibitRules

Deployment/alert-webhook + Service/alert-webhook
  -> 本地通知接收端
```

## 2. SLI/SLO 定义

### 2.1 SLI

可用性 SLI：

```promql
成功请求速率 / 总请求速率
```

成功请求定义为 2xx 和 3xx：

```promql
sum(rate(demo_http_requests_total{status=~"2..|3.."}[5m]))
/
sum(rate(demo_http_requests_total[5m]))
```

### 2.2 SLO

```text
demo 可用性 >= 99.0%，7 天滚动窗口
```

允许的错误比例：

```text
1 - 0.99 = 0.01 = 1%
```

这 1% 就是 7 天的错误预算。

为什么用 7 天：

- 与 Prometheus、Loki、Tempo 的 7 天保留期一致。
- 足以覆盖一个完整的周周期。
- 实验环境数据量小，7 天窗口可解释、可验证。

### 2.3 燃烧率

```promql
clamp_min(1 - SLI, 0) / 0.01
```

含义：

| 燃烧率 | 预算耗尽时间（持续该速率） |
|---:|---:|
| `1x` | 约 7 天 |
| `6x` | 约 28 小时 |
| `14.4x` | 约 11.7 小时 |

### 2.4 四个窗口

| 窗口 | recording rule | 用途 |
|---|---|---|
| 5m | `demo:sli_availability:ratio_rate5m` | 快速发现突发错误 |
| 1h | `demo:sli_availability:ratio_rate1h` | 确认错误持续 |
| 30m | `demo:sli_availability:ratio_rate30m` | 中等时间尺度 |
| 6h | `demo:sli_availability:ratio_rate6h` | 慢速预算消耗 |

燃烧率 recording rules：

```text
demo:error_budget_burn_rate5m
demo:error_budget_burn_rate1h
demo:error_budget_burn_rate30m
demo:error_budget_burn_rate6h
```

### 2.5 告警阈值

FastBurn：

```text
5m > 14.4 且 1h > 14.4
for: 2m
severity: critical
```

SlowBurn：

```text
30m > 6 且 6h > 6
for: 15m
severity: warning
```

NoTraffic：

```text
5m 请求速率为 0，或者没有 SLI 数据
for: 10m
severity: warning
```

## 3. 指标和抓取验收

### 3.1 `/metrics` 输出

实际计数：

```text
demo_http_requests_total{method="GET",path="/",status="200"} 3.0
demo_http_requests_total{method="GET",path="other",status="200"} 1.0
```

验证点：

- 请求 `/` 会计数。
- 未知路径归一化为 `path="other"`，避免路径爆炸。
- 连续读取 `/metrics` 不会增加业务计数。
- `/metrics` 和 `/healthz` 不写业务日志，也不创建 trace。

### 3.2 ServiceMonitor 和 target

```text
ServiceMonitor/log-demo 存在
Service 标签 app=log-demo
up{namespace="demo"} => 1
up{job=~".*log-demo.*"} => 1
sum(rate(demo_http_requests_total[5m])) => 0.498
```

说明：

- `ServiceMonitor` 通过 `namespaceSelector: demo` 和 `selector.matchLabels.app=log-demo` 找到 Service。
- `endpoints.port: http` 使用的是 Service 端口名，不是 8080。
- 抓取间隔 15 秒，超时 10 秒。

## 4. 规则验收

### 4.1 正常流量

```text
demo:sli_availability:ratio_rate5m => 1
demo:sli_availability:ratio_rate1h => 1
demo:error_budget_burn_rate5m => 0
demo:error_budget_burn_rate1h => 0
```

`ALERTS{alertstate="firing"}` 只有平台自带的：

```text
Watchdog
InfoInhibitor
```

没有 demo 告警。

### 4.2 规则加载延迟

第一次 apply 后立刻查询得到 `[]`，约 30 秒后 recording rule 才有样本。原因是：

```text
PrometheusRule apply
  -> Operator 生成规则文件
  -> Prometheus reload
  -> 下一个 evaluation interval
  -> recording rule 产生样本
```

这不是配置失败。

### 4.3 无流量

loadgen 缩容到 0 后 6 分钟：

```text
FastBurn / SlowBurn => []
DemoNoTraffic => pending
sum(rate(demo_http_requests_total[5m])) => 0
```

`DemoNoTraffic` 为 pending，因为 `for: 10m` 还没满足。恢复 loadgen 后 60 秒：

```text
请求速率 => 0.495
Demo.* 告警 => []
```

## 5. Webhook 验收

`alert-webhook` 是一个 Python 标准库 HTTP 服务：

```text
GET  /healthz            -> 200 ok
POST /webhook/default     -> 记录 JSON
POST /webhook/critical    -> 记录 JSON
POST /webhook/warning     -> 记录 JSON
```

实际测试：

```text
health: ok
post: ok
```

日志：

```json
{
  "ts": "...",
  "path": "/webhook/test",
  "payload": {
    "status": "firing",
    "alerts": [{"labels": {"alertname": "WebhookTest"}}]
  }
}
```

## 6. Alertmanager 配置验收

### 6.1 生成配置

AlertmanagerConfig 创建后：

```text
alertmanagerconfig/demo-alerting 存在
Alertmanager RECONCILED=True
Alertmanager AVAILABLE=True
```

生成的配置包含：

```text
receiver: monitoring/demo-alerting/webhook-default
group_by: [alertname, service, severity]
routes:
  - webhook-critical, severity="critical", repeat_interval 30m
  - webhook-warning, severity="warning", repeat_interval 2h
inhibit_rules:
  - source severity="critical"
    target severity="warning"
    equal [service, slo]
```

同时 Operator 自动加入：

```text
namespace="monitoring"
```

原因：AlertmanagerConfig 默认 `OnNamespace`。没有这个标签的告警不会命中自定义路由或抑制规则。

### 6.2 根路由仍是 null

生成配置的根路由是：

```yaml
route:
  receiver: "null"
```

这是平台默认路由。我们的配置是一个 `namespace="monitoring"` 的子路由，带有 `continue: true`，因为根路由后面还有 Watchdog 路由。Watchdog 只匹配自身，不会导致 demo 告警重复发送。

## 7. 路由、分组、抑制、静默验收

### 7.1 critical 路由

合成告警：

```text
TestCritical
severity=critical
service=test-routing
slo=test
namespace=monitoring
```

结果：

```text
POST /api/v2/alerts -> 200
webhook path -> /webhook/critical
alertname -> TestCritical
```

### 7.2 warning 分组

两条 `TestGroup` warning：

```text
instance=test-a
instance=test-b
```

`instance` 不在 `groupBy` 中，所以合并为一个通知。

结果：

```text
POST -> 200
webhook path -> /webhook/warning
payload alerts 数组 -> 2 条 TestGroup
groupLabels -> alertname/service/severity，没有 instance
```

### 7.3 抑制

同时发送：

```text
TestInhibitCritical  severity=critical  service=test-inhibit  slo=test
TestInhibitWarning   severity=warning   service=test-inhibit  slo=test
```

结果：

```text
TestInhibitWarning state=suppressed
inhibitedBy=[critical fingerprint]
TestInhibitCritical state=active
webhook 只有 /webhook/critical
```

说明 critical 抑制了同 `service`/`slo` 的 warning。

### 7.4 静默

静默匹配：

```text
alertname=TestSilence
```

发送 `TestSilence` 后：

```text
silenceID=955d7a6a-9862-44dd-9818-10f375e41006
state=suppressed
silencedBy=[955d7a6a-9862-44dd-9818-10f375e41006]
webhook 没有 TestSilence
```

删除静默返回 `200`。

### 7.5 清理

先恢复 warning，再恢复 critical：

```text
resolve warnings -> 200
resolve criticals -> 200
remaining Test alerts: []
```

## 8. 真实故障注入

### 8.1 注入

```bash
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/error
kubectl rollout status deployment/demo-loadgen -n demo
```

### 8.2 3 分钟观察

```text
sum(rate(demo_http_requests_total{status="500"}[5m])) => 0.300
demo:error_budget_burn_rate5m => 55.08
demo:error_budget_burn_rate1h => 4.88
FastBurn => []
```

5 分钟窗口里还包含切换前的成功请求，所以 500 速率不是 0.5，燃烧率也不是 100x。

### 8.3 约 12 分钟后

```text
demo:error_budget_burn_rate5m => 100
demo:error_budget_burn_rate1h => 30.59
demo:error_budget_burn_rate30m => 60.83
demo:error_budget_burn_rate6h => 11.13
ALERTS DemoAvailabilityFastBurn => firing
ALERTS DemoAvailabilitySlowBurn => pending
Alertmanager DemoAvailabilityFastBurn => active
webhook -> /webhook/critical, DemoAvailabilityFastBurn
```

时间线：

| 时间（UTC） | 事件 |
|---|---|
| 12:55 | loadgen 切到 `/error` |
| 13:06:39 | FastBurn 开始 firing |
| 13:20:09 | SlowBurn 开始 firing |
| 13:22:09 | FastBurn resolved |
| 13:22:19 | webhook 收到 SlowBurn firing 和 FastBurn resolved |

### 8.4 恢复

```bash
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/
kubectl rollout status deployment/demo-loadgen -n demo
```

5 分钟后：

```text
demo:error_budget_burn_rate5m => 0
demo:error_budget_burn_rate1h => 36.70
DemoAvailabilityFastBurn => resolved
DemoAvailabilitySlowBurn => firing
webhook -> /webhook/critical status=resolved
webhook -> /webhook/warning DemoAvailabilitySlowBurn status=firing
```

### 8.5 SlowBurn 已知偏差

SlowBurn 在 FastBurn 恢复后仍然 firing，原因是 30m/6h 窗口保留了故障期间的错误。

这不是路由或规则错误：

- 30m/6h 燃烧率确实 > 6。
- `for: 15m` 确实满足。
- 它需要接近 6 小时让错误样本离开 6h 窗口，才会自然恢复。

另外，12 分钟全错误按 6h 窗口计算，燃烧率约 `3.3x`，不应超过 6。实际 `6h=11.13x`，说明窗口里还有更早的 500，或者 `rate()` 在数据不足时有外推。这是实验基线没有完全隔离的表现。

处理方式：记录为已知偏差，不修改阈值，不伪造 resolved，也没有创建静默来掩盖它。

## 9. 资源占用

命令：

```bash
kubectl top pods -n demo
kubectl top pods -n monitoring
kubectl top nodes
```

结果：

| Pod / 节点 | CPU | 内存 |
|---|---:|---:|
| `demo-loadgen` | 2m | 0Mi |
| `log-demo` | 1m | 31Mi |
| `web` × 2 | 各 1m | 各 10Mi |
| `alert-webhook` | 1m | 14Mi |
| `alertmanager` | 1m | 76Mi |
| `prometheus` | 22m | 511Mi |
| `grafana` | 17m | 515Mi |
| `kube-state-metrics` | 1m | 68Mi |
| `prometheus-operator` | 3m | 80Mi |
| node-exporter × 3 | 2m / 2m / 1m | 25Mi / 25Mi / 9Mi |
| `k8s-server` | 105m（2%） | 3541Mi（60%） |
| `k8s-worker-1` | 32m（1%） | 1419Mi（48%） |
| `k8s-worker-2` | 29m（0%） | 1368Mi（46%） |

结论：

- `demo-loadgen` 和 `alert-webhook` 都是小资源工作负载。
- 节点内存没有接近 80%。
- Prometheus 规则评估没有造成明显 CPU 压力。

## 10. 偏差与已知问题

1. **namespace 匹配**：AlertmanagerConfig 默认 `OnNamespace`，最初 demo 告警没有 `namespace: monitoring`，会导致路由和抑制不命中。已给三个 demo 告警补上该标签。
2. **规则加载延迟**：apply 后第一次查询为空，约 30 秒后 recording rule 才有样本。
3. **合成测试相互影响**：critical 会抑制同 `service`/`slo` 的 warning。测试使用 `test-routing`、`test-group`、`test-inhibit`、`test-silence` 四个不同 service，避免前面的 critical 干扰后面的测试。
4. **SlowBurn 长窗口**：FastBurn 恢复后 SlowBurn 仍 firing，未等待 6 小时自然恢复。
5. **6h 基线不干净**：6h 燃烧率高于仅由 12 分钟故障推算的值，说明窗口里有历史错误或 `rate()` 外推。
6. **Alertmanager 根路由**：生成配置根路由仍是 `receiver: "null"`，自定义配置是子路由；这是 Operator 合并配置的正常结果。
7. **webhook 安全边界**：没有认证、TLS、请求体大小限制，只适合集群内实验环境。

## 11. 未完成项

- 没有真实等待 SlowBurn 的 6h 窗口完全稀释。
- 没有接真实 IM/邮件通知，只接本地 webhook。
- 没有做 Alertmanager 多副本/高可用。
- 没有做 webhook 认证、TLS、限流和脱敏。
- 没有把告警接入阶段 6 的 AI 摘要服务。

## 12. 复现命令

```bash
# 组件状态
kubectl get prometheusrule,servicemonitor,alertmanagerconfig -n monitoring
kubectl get deploy,pod,svc -n demo
kubectl get deploy,pod,svc -n monitoring -l app=alert-webhook
kubectl get alertmanager -n monitoring kube-prometheus-stack-alertmanager

# 生成后的 Alertmanager 配置
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- zcat /etc/alertmanager/config/alertmanager.yaml.gz

# 正常 SLI
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.parse
import urllib.request

base = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
for expr in [
    "demo:sli_availability:ratio_rate5m",
    "demo:error_budget_burn_rate5m",
    'ALERTS{alertname=~"Demo.*"}',
]:
    url = base + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    print(expr, "=>", json.load(urllib.request.urlopen(url))["data"]["result"])
PY

# 故障注入
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/error
kubectl rollout status deployment/demo-loadgen -n demo

# 恢复
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/
kubectl rollout status deployment/demo-loadgen -n demo
```

## 13. 快照

重启后验证：

```text
k8s-server     Ready   control-plane
k8s-worker-1   Ready   <none>
k8s-worker-2   Ready   <none>
```

Pod 状态：

| 命名空间 | 结果 |
|---|---|
| `monitoring` | Alertmanager、Prometheus、Grafana、Operator、kube-state-metrics、node-exporter、alert-webhook 全部 `Running` |
| `demo` | `log-demo`、`demo-loadgen`、`web` 全部 `Running` |
| `logging` | `loki-0`、三个 `fluent-bit` 全部 `Running` |
| `tracing` | `tempo-0`、`otel-collector` 全部 `Running` |

重启后 RESTARTS 计数增加是正常现象，代表容器随节点重启重新拉起，不代表 CrashLoopBackOff。

Alertmanager UI `http://172.25.254.10:30093` 正常，能看到：

- `monitoring/demo-alerting/webhook-warning` → `DemoAvailabilitySlowBurn`
- `monitoring/demo-alerting/webhook-default` → `CPUThrottlingHigh`
- `null` 未分组告警（平台默认）

webhook 重启后测试：

```text
POST /webhook/test -> 200
日志 path=/webhook/test
payload alertname=SnapshotTest
```

快照名称：

```text
phase-5-alerting-ready
```

三台 VM 的快照创建结果：用户确认三台均已创建 `phase-5-alerting-ready` 快照。

## 14. 结论

阶段 5 的核心链路已经打通：

```text
/metrics
  -> ServiceMonitor
  -> Prometheus SLI/burn-rate rules
  -> ALERTS
  -> Alertmanager route/group/inhibit/silence
  -> alert-webhook
  -> kubectl logs
```

可以确认：

- 真实 500 能让 FastBurn firing。
- critical 能路由到 `/webhook/critical`。
- 恢复后 FastBurn 能 resolved，webhook 收到 resolved。
- warning 分组、critical 抑制 warning、静默都按配置工作。
- SlowBurn 的长窗口行为已记录为已知偏差，没有通过改阈值掩盖。

下一步：进入阶段 6（AI 告警摘要）。
