# 阶段 5 告警与 SLO YAML / PromQL 解释

> 对应文件：
> - [`infra/tracing/demo-service-otel.yaml`](../../infra/tracing/demo-service-otel.yaml)
> - [`infra/alerting/demo-servicemonitor.yaml`](../../infra/alerting/demo-servicemonitor.yaml)
> - [`infra/alerting/demo-loadgen.yaml`](../../infra/alerting/demo-loadgen.yaml)
> - [`infra/alerting/demo-slo-rules.yaml`](../../infra/alerting/demo-slo-rules.yaml)
> - [`infra/alerting/alert-webhook.yaml`](../../infra/alerting/alert-webhook.yaml)
> - [`infra/alerting/alertmanager-config.yaml`](../../infra/alerting/alertmanager-config.yaml)
>
> 这篇文档回答：
> 1. 文件是什么类型，谁读取它？
> 2. 每个关键字段在做什么，不写或写错会怎样？
> 3. 它对应告警从指标到通知的哪一段？
>
> 实际验收结果见：[阶段 5 告警与 SLO 验收记录](06-phase-5-acceptance.md)。

## 0. 先分清五类文件

### 应用清单

```text
infra/tracing/demo-service-otel.yaml
```

这是 demo 的 ConfigMap、Deployment、Service。它负责：

- 暴露 `/metrics`
- 记录请求计数和延迟
- 把未知路径归一化为 `path="other"`
- `/metrics`、`/healthz` 在创建 trace 和写业务日志之前返回

### 抓取配置

```text
infra/alerting/demo-servicemonitor.yaml
```

这是 `ServiceMonitor`，Prometheus Operator 的 CRD。它告诉 Prometheus：

> 去 `demo` 命名空间，找带 `app=log-demo` 的 Service，抓名为 `http` 的端口，路径 `/metrics`。

它本身不抓数据，Operator 会把它转换成 Prometheus 的 scrape config。

### 流量生成器

```text
infra/alerting/demo-loadgen.yaml
```

这是 BusyBox Deployment，每 2 秒请求一次 demo，约 `0.5 req/s`。

没有它，demo 的计数器不会增长，SLI 和燃烧率会没有数据。

### 规则

```text
infra/alerting/demo-slo-rules.yaml
```

这是 `PrometheusRule`，包含两类规则：

- `record`：计算 SLI 和燃烧率，写入新的时间序列。
- `alert`：读取燃烧率，决定是否产生告警。

### 通知配置

```text
infra/alerting/alert-webhook.yaml
infra/alerting/alertmanager-config.yaml
```

- `alert-webhook.yaml`：ConfigMap + Deployment + Service，运行 Python 接收器。
- `alertmanager-config.yaml`：`AlertmanagerConfig`，配置路由、分组、接收器和抑制规则。

---

## 1. 全景数据流

```text
loadgen
  |
  | GET / 或 /error
  v
demo Service
  |
  v
demo /metrics
  |
  | ServiceMonitor 每 15s 抓取
  v
Prometheus
  |
  | PrometheusRule 每 30s 评估
  v
ALERTS
  |
  v
Alertmanager
  |
  +-- critical -> /webhook/critical
  +-- warning  -> /webhook/warning
  +-- 其他      -> /webhook/default
                        |
                        v
                 alert-webhook
                        |
                        v
                   kubectl logs
```

---

## 2. demo 的指标

### 2.1 为什么先加 `/metrics`

kube-state-metrics 只能告诉你 Kubernetes 对象的状态，例如：

- Deployment 有多少副本
- Pod 是否 Ready
- 容器是否重启

它不知道业务请求成功了多少、失败了多少。

要算业务可用性，必须让应用自己暴露请求结果：

```promql
demo_http_requests_total{method="GET",path="/",status="200"}
```

所以先给 demo 加 `/metrics`，再谈 SLO。

### 2.2 Counter

```python
demo_http_requests_total = Counter(
    "demo_http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)
```

Counter 是只增不减的计数器。适合表示：

- 请求总数
- 错误总数
- 字节总数

查询时不能直接看 Counter 的当前值，而要用 `rate()` 看增长速率：

```promql
rate(demo_http_requests_total[5m])
```

### 2.3 Histogram

```python
demo_http_request_duration_seconds = Histogram(
    "demo_http_request_duration_seconds",
    "HTTP request duration",
    ["method", "path"],
)
```

Histogram 把请求耗时分桶，例如：

```text
0.005s
0.01s
0.025s
0.05s
0.1s
0.25s
0.5s
1s
2.5s
5s
10s
```

它会产生：

```text
demo_http_request_duration_seconds_bucket
demo_http_request_duration_seconds_sum
demo_http_request_duration_seconds_count
```

计算 P95 延迟：

```promql
histogram_quantile(
  0.95,
  sum by (le) (rate(demo_http_request_duration_seconds_bucket[5m]))
)
```

阶段 5 的告警主要用可用性，不直接用延迟，但延迟直方图保留给后续排障和阶段 6 的 AI 上下文。

### 2.4 为什么 path 要归一化

如果把原始路径直接做标签：

```text
/user/123
/user/456
/user/789
```

每个用户 ID 都会生成一条新时间序列，导致**标签基数爆炸**。

demo 只保留已知路径：

```text
/
/error
```

其他路径统一写成：

```text
other
```

这样时间序列数量可控。

### 2.5 为什么 trace_id 不能做标签

`trace_id` 每次请求都不同。如果把它放进 Prometheus 标签：

- 每次请求都会创建新时间序列
- Prometheus 内存和索引会迅速膨胀
- 查询会变得非常慢

`trace_id` 属于日志和 trace 的关联字段，不属于指标标签。

### 2.6 为什么 `/metrics` 和 `/healthz` 要绕过业务逻辑

如果 `/metrics` 也计数：

- Prometheus 每抓取一次，就增加一次请求数
- 抓取频率会影响业务 SLI
- 指标自己污染自己

如果 `/healthz` 也写日志和 trace：

- readiness probe 每 5 秒生成一条日志
- 每 5 秒生成一个 trace
- 日志和 trace 被探针淹没

所以这两个路径在创建 span 和写业务日志之前直接返回。

---

## 3. ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: log-demo
  namespace: monitoring
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

### 3.1 `namespaceSelector`

只在 `demo` 命名空间里找 Service。

写错会怎样：

- 写成 `monitoring`：找不到 demo
- 写成 `default`：找不到 demo
- 不写：通常只在同命名空间找，也找不到

### 3.2 `selector.matchLabels`

选择带 `app=log-demo` 的 Service。

这就是为什么 demo Service 必须有：

```yaml
metadata:
  labels:
    app: log-demo
```

只有 Pod selector 没有 Service 标签时，ServiceMonitor 选不到 Service。

### 3.3 `endpoints.port`

这里写的是 **Service 端口名**，不是端口号：

```yaml
ports:
  - name: http
    port: 8080
    targetPort: http
```

所以 ServiceMonitor 写 `port: http`，不是 `8080`。

### 3.4 判断成功的标准

不是看 `kubectl get servicemonitor` 存在，而是看 Prometheus：

```promql
up{namespace="demo"}
```

- 有结果且为 `1`：target 发现且抓取成功
- 有结果且为 `0`：target 发现但抓取失败
- 没有结果：ServiceMonitor 没选中 Service，或端口名/标签/命名空间错

---

## 4. loadgen

```yaml
command:
  - /bin/sh
  - -c
  - |
    while true; do
      wget -q -T 2 -O /dev/null \
        "http://log-demo.demo.svc.cluster.local:8080${TARGET_PATH}" || true
      sleep "${INTERVAL_SECONDS}"
    done
```

### 4.1 为什么需要 loadgen

SLO 不能靠手动点几次请求计算。没有持续流量时：

```promql
sum(rate(demo_http_requests_total[5m]))
```

会没有数据，SLI 和燃烧率也无法计算。

### 4.2 为什么是 0.5 req/s

```text
INTERVAL_SECONDS=2
-> 每 2 秒一次
-> 约 0.5 req/s
```

5 分钟窗口大约有 150 个请求，足够算比例，又不会把 Loki/Tempo 写爆。

### 4.3 为什么有 `|| true`

`/error` 返回 500 时，`wget` 会返回非 0。如果没有 `|| true`，脚本会退出，loadgen 停止。

### 4.4 故障开关

```bash
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/error
kubectl set env deployment/demo-loadgen -n demo TARGET_PATH=/
```

`set env` 会触发 Deployment 滚动更新。

---

## 5. SLO 规则

### 5.1 99% SLO 和 7 天错误预算

```text
SLO = 99%
允许错误比例 = 1 - 0.99 = 0.01
窗口 = 7 天
```

错误预算就是这 1%。

### 5.2 燃烧率公式

```promql
clamp_min(1 - SLI, 0) / 0.01
```

假设 SLI 是 0.98：

```text
1 - 0.98 = 0.02
0.02 / 0.01 = 2x
```

含义：按当前速度，7 天预算会在约 3.5 天用完。

### 5.3 为什么分母是 0.01

因为允许错误比例是 1%，也就是 0.01。

如果 SLO 改成 99.9%，允许错误比例就是 0.001，分母也要改成 0.001。

### 5.4 为什么 FastBurn 要两个窗口

只看 5 分钟：

- 一次短暂尖峰就可能误报
- 流量小的时候比例波动大

只看 1 小时：

- 发现太慢

两个都看：

```text
5m > 14.4 且 1h > 14.4
```

既快，又能确认错误是持续的。

### 5.5 为什么 SlowBurn 要两个窗口

```text
30m > 6 且 6h > 6
```

30m 负责发现中等长度的持续错误，6h 负责确认长期预算消耗。

代价是恢复很慢：故障结束后，6h 窗口里的错误还会保留很久。阶段 5 实际验收中就观察到了这一点。

### 5.6 `record` 和 `alert`

```yaml
- record: demo:sli_availability:ratio_rate5m
  expr: ...
```

`record` 只计算，不告警。结果会变成新的时间序列，Grafana 可以直接查。

```yaml
- alert: DemoAvailabilityFastBurn
  expr: ...
  for: 2m
```

`alert` 读取时间序列，条件为真并持续 `for` 后，产生 `ALERTS`。

### 5.7 为什么成功分子要加 `or vector(0)`

如果 5 分钟内全部请求失败：

```promql
sum(rate(demo_http_requests_total{status=~"2..|3.."}[5m]))
```

没有任何匹配序列，PromQL 返回“无数据”，不是 0。

无数据除以有数据，结果还是无数据，燃烧率不会触发。

加上：

```promql
or vector(0)
```

全错误时分子返回 0，SLI 变成 0，燃烧率才能正确升高。

### 5.8 NoTraffic 为什么要 `absent`

```promql
sum(rate(demo_http_requests_total[5m])) == 0
or
absent(sum(rate(demo_http_requests_total[5m])))
```

- `== 0`：有指标，但请求速率为 0。
- `absent(...)`：连指标都没有，例如 demo 挂了或抓取失败。

两种情况都表示 SLI 不可信。

### 5.9 为什么要 `namespace: monitoring`

AlertmanagerConfig 默认 `OnNamespace`，只处理带 `namespace: monitoring` 的告警。

所以三个 demo 告警都加了：

```yaml
labels:
  severity: ...
  service: demo
  slo: availability
  namespace: monitoring
```

---

## 6. webhook 接收器

### 6.1 ConfigMap 保存代码

```yaml
data:
  webhook.py: |
    ...
```

ConfigMap 把 Python 代码挂载到 `/app/webhook.py`，不需要构建镜像。

修改 ConfigMap 后，Pod 不会自动加载新代码，需要：

```bash
kubectl rollout restart deployment/alert-webhook -n monitoring
```

### 6.2 GET `/healthz`

```python
if self.path == "/healthz":
    self._send(200, "ok\n")
```

readiness/liveness probe 请求它。

### 6.3 POST

```python
length = int(self.headers.get("Content-Length", "0"))
raw = self.rfile.read(length).decode("utf-8", errors="replace")
payload = json.loads(raw)
```

读取 Alertmanager 发来的 JSON，然后打印：

```json
{
  "ts": "...",
  "path": "/webhook/critical",
  "payload": {...}
}
```

### 6.4 为什么用单线程

实验环境告警量很小，单线程 `HTTPServer` 足够。

生产环境通常需要：

- 多线程/异步
- TLS
- 认证
- 请求体大小限制
- 脱敏
- 限流

---

## 7. AlertmanagerConfig

### 7.1 和直接改 `alertmanager.yaml` 的区别

直接改 `alertmanager.yaml`：

- 需要自己管理 Secret/ConfigMap
- 需要自己触发 reload
- 容易被 Helm 升级覆盖

`AlertmanagerConfig`：

- 是 Kubernetes CRD
- Operator 监听并合并到最终配置
- 可以用 Git 管理
- 多个团队可以各自维护配置片段

### 7.2 路由

```yaml
route:
  receiver: webhook-default
  groupBy:
    - alertname
    - service
    - severity
  routes:
    - receiver: webhook-critical
      matchers:
        - name: severity
          value: critical
          matchType: "="
    - receiver: webhook-warning
      matchers:
        - name: severity
          value: warning
          matchType: "="
```

路由树：

```text
root
  +-- critical -> critical webhook
  +-- warning  -> warning webhook
  +-- 其他      -> default webhook
```

### 7.3 分组

`groupBy` 决定哪些告警合并成一个通知。

这里按：

```text
alertname
service
severity
```

分组，所以两个只有 `instance` 不同的 warning 会合并。

### 7.4 时间参数

- `groupWait`：第一条告警后等多久收齐同组告警
- `groupInterval`：同组后续新增告警多久补发
- `repeatInterval`：持续 firing 时多久重复通知

### 7.5 接收器

```yaml
webhookConfigs:
  - url: http://alert-webhook.monitoring.svc.cluster.local:8080/webhook/critical
    sendResolved: true
```

`sendResolved: true` 表示恢复时也发通知。

### 7.6 抑制

```yaml
inhibitRules:
  - sourceMatch:
      - name: severity
        value: critical
    targetMatch:
      - name: severity
        value: warning
    equal:
      - service
      - slo
```

含义：

> critical 存在时，抑制同 `service`/`slo` 的 warning。

为什么 `equal` 是 `service`/`slo`：

- 只抑制同一个服务的同一个 SLO
- 不相关服务的 warning 不会被误压

### 7.7 为什么生成配置里有 `namespace="monitoring"`

AlertmanagerConfig 默认：

```yaml
alertmanagerConfigMatcherStrategy:
  type: OnNamespace
```

Operator 会自动加：

```yaml
namespace="monitoring"
```

如果告警没有这个标签，就不会命中自定义路由或抑制规则。

### 7.8 根路由为什么还是 `null`

平台默认配置有根路由和 Watchdog 子路由。Operator 把我们的配置作为子路由插入，所以根路由保留 `receiver: "null"`。

自定义子路由带 `continue: true`，是为了让后面的 Watchdog 路由仍能继续匹配。Watchdog 只匹配自己，不会导致 demo 告警重复通知。

---

## 8. 抑制和静默的区别

| 项 | 抑制 | 静默 |
|---|---|---|
| 谁触发 | 规则自动 | 人手动 |
| 生命周期 | 只要源告警存在 | 指定开始/结束时间 |
| 典型场景 | critical 压掉同服务 warning | 维护窗口、已知噪声 |
| 是否修改告警状态 | 标记 `suppressed`/`inhibitedBy` | 标记 `suppressed`/`silencedBy` |
| 是否等于恢复 | 否 | 否 |

静默删除后，如果告警条件仍然成立，通知会恢复。

---

## 9. 常见错误

| 现象 | 原因 | 先查 |
|---|---|---|
| `up{namespace="demo"}` 为空 | ServiceMonitor 没选中 Service | Service 标签、namespaceSelector、端口名 |
| `up=0` | 抓取失败 | `/metrics` 是否通、端口是否对 |
| SLI 无数据 | 没有流量或指标名错 | loadgen、`demo_http_requests_total` |
| 全错误时燃烧率无数据 | 成功分子为空 | 加 `or vector(0)` |
| PrometheusRule apply 后查询为空 | 还没到 evaluation interval | 等 30–60 秒 |
| Alertmanager 配置没合并 | AlertmanagerConfig 没被 selector 选中 | `alertmanagerConfigSelector`、Operator 日志 |
| 路由/抑制不生效 | 告警缺 `namespace: monitoring` | `alertmanagerConfigMatcherStrategy`、告警标签 |
| webhook 没日志 | 只发了 GET，或 Service 没有 endpoints | POST、`kubectl get endpoints` |
| webhook 503 | Pod 没 Ready 或进程挂了 | readiness、`kubectl logs` |
| SlowBurn 长时间不恢复 | 30m/6h 长窗口保留旧错误 | 燃烧率窗口、历史错误 |
| 静默忘记删除 | 手动资源没有清理 | `GET /api/v2/silences` |

---

## 10. 复现顺序

```text
1. demo 暴露 /metrics
2. ServiceMonitor 选中 demo Service
3. loadgen 制造持续流量
4. PrometheusRule 计算 SLI 和燃烧率
5. 确认正常流量无告警
6. 部署 webhook
7. 配置 AlertmanagerConfig
8. 用合成告警测试路由/分组/抑制/静默
9. 用 /error 做真实故障注入
10. 恢复流量，确认 FastBurn resolved
11. 记录 SlowBurn 长窗口偏差
```

对应文件：

```text
infra/tracing/demo-service-otel.yaml
infra/alerting/demo-servicemonitor.yaml
infra/alerting/demo-loadgen.yaml
infra/alerting/demo-slo-rules.yaml
infra/alerting/alert-webhook.yaml
infra/alerting/alertmanager-config.yaml
```

实际结果见：[阶段 5 告警与 SLO 验收记录](06-phase-5-acceptance.md)。
