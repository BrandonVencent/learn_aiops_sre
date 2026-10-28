# 阶段 6 AI 告警摘要验收记录

> 状态：6a（现有 `/error` 500 场景）和 6b（下游超时场景）均验收通过；三台 VM 已创建 `phase-6a-ai-summary-ready` 和 `phase-6-ai-summary-ready` 快照。
> 设计见 [阶段 6 AI 告警摘要设计](../superpowers/specs/phase-6-ai-alert-summary-design.md)，执行计划见 [阶段 6 AI 告警摘要计划](../superpowers/plans/phase-6-ai-alert-summary.md)。
> 本记录只写配置、命令和验证结果，不记录 DeepSeek API key、钉钉 webhook、加签 SEC 或任何密码。

## 环境

| 项 | 值 |
|---|---|
| 宿主机 | Windows，16 GB 内存，14 核 20 线程 |
| VMware 网络 | `VMnet8`，`172.25.254.0/24`，网关 `172.25.254.2` |
| `k8s-server` | `172.25.254.10/24`，4C / 6 GB |
| `k8s-worker-1` | `172.25.254.11/24`，2C / 3 GB |
| `k8s-worker-2` | `172.25.254.12/24`，2C / 3 GB |
| 系统 | Ubuntu Server 22.04.5 LTS |
| 集群 | k3s `v1.36.5+k3s1` |
| 服务命名空间 | `aiops` |
| 告警数据源 | `monitoring`（Prometheus / Alertmanager） |
| 日志数据源 | `logging`（Loki） |
| 链路数据源 | `tracing`（Tempo） |
| demo 命名空间 | `demo` |
| 服务运行时 | `python:3.12-slim` + FastAPI + uvicorn |
| 服务清单 | [`infra/aiops/ai-summary.yaml`](../../infra/aiops/ai-summary.yaml) |
| 抓取配置 | [`infra/aiops/ai-summary-servicemonitor.yaml`](../../infra/aiops/ai-summary-servicemonitor.yaml) |
| 路由配置 | [`infra/alerting/alertmanager-config.yaml`](../../infra/alerting/alertmanager-config.yaml) |
| Secret | `aiops/ai-summary-secrets`，键为 `DEEPSEEK_API_KEY`、`DINGTALK_WEBHOOK`、`DINGTALK_SECRET`（不记录值） |
| ai-summary 资源 | request `100m / 128Mi`，limit `500m / 384Mi`，单副本 |
| inventory 清单 | [`infra/aiops/inventory-service.yaml`](../../infra/aiops/inventory-service.yaml) |
| inventory 资源 | request `50m / 64Mi`，limit `200m / 128Mi`，单副本 |
| loadgen 清单 | [`infra/alerting/demo-loadgen.yaml`](../../infra/alerting/demo-loadgen.yaml) |
| demo 清单 | [`infra/tracing/demo-service-otel.yaml`](../../infra/tracing/demo-service-otel.yaml) |
| 通知渠道 | 钉钉群机器人（加签），邮件兜底未启用 |

## 验收清单

- [x] `aiops` 命名空间和 Secret 创建成功，`DATA=3`
- [x] `ai-summary` Pod `Running`，`/healthz` 返回 200
- [x] Alertmanager webhook 在 200ms 内返回 `202`（实测 11.8ms）
- [x] 10 分钟内重复投递被去重，不重复调模型、不重复发钉钉
- [x] 钉钉加签发送成功，`errcode=0`
- [x] Prometheus 证据可采集，M1/M3/M5 与手工 PromQL 完全一致
- [x] Loki 证据可采集，`L1_COUNT=149`，错误日志可读
- [x] Tempo 证据可采集，T1 包含错误 span
- [x] 6a 真实 500：FastBurn firing → P1 卡片 → resolved 卡片
- [x] 卡片置信度由服务端按证据覆盖计算，100%（指标 + 日志 + 链路）
- [x] 根因不出现 `inventory`、数据库、Redis、MySQL 等无证据结论
- [x] 提示词注入被过滤，卡片不出现注入要求
- [x] `LLM_ENABLED=0` 时仍能发出规则降级卡片
- [x] 无流量场景输出 P3 / 33% / 证据不足，NaN 不进入卡片
- [x] 日志中未出现 API key、钉钉 token、SEC
- [x] `ai-summary` 内存 50Mi，低于 200Mi
- [x] ServiceMonitor target `job=ai-summary` 为 `up=1`
- [x] 三台 VM 创建 `phase-6a-ai-summary-ready` 快照（2026-10-26 21:00:36 +08:00）
- [x] `inventory` 服务正常，`/item` 返回 `{"item":"ok"}`
- [x] demo `/checkout` 正常返回 `ok`，指标出现 `path="/checkout"`
- [x] 6b 注入 `DELAY_MS=5000` 后 `/checkout` 返回 504，P95 超过 2 秒
- [x] 6b 卡片 P1 / 100%，根因指向 inventory 下游超时
- [x] 6b 证据含 `M6`、`L1`、`T1`、`T2`
- [x] 6a 卡片不含 `inventory`，6b 卡片与 6a 正文可区分
- [x] 6b 恢复后 FastBurn resolved，钉钉收到恢复卡片
- [x] `inventory` 内存低于 80Mi
- [x] 三台 VM 创建 `phase-6-ai-summary-ready` 快照（2026-10-28）

## 1. 目标与边界

阶段 6 要回答的问题是：

> 当一条 SLO 告警真的响起时，服务能不能在几十秒内给出“发生了什么、证据是什么、先查哪里”，而不是复述告警标题？

两个场景：

- 6a：现有 `/error` 路径立即返回 500，验证“错得快”的故障；
- 6b：`/checkout` 调用 `inventory` 超时，验证“慢到超时”的故障，以及同一套采集能否给出不同根因。

边界：

- 只处理 demo 的三个告警：`DemoAvailabilityFastBurn`、`DemoAvailabilitySlowBurn`、`DemoNoTraffic`。
- 只读 Prometheus、Loki、Tempo 和 Alertmanager 传来的告警内容。
- 不执行重启、回滚、扩缩容等运维动作，这些属于阶段 7。
- 通知只发钉钉群，邮件兜底保留但未启用。
- 模型只做归纳，不参与置信度、优先级和证据校验。

## 2. 数据流

```text
PrometheusRule/demo-slo
  -> ALERTS
  -> Alertmanager
       |
       +-- continue: true --> ai-summary.aiops:8080/webhook/alert
       |                          |
       |                          +-- 202 立即返回
       |                          +-- 后台任务
       |                                +-- Prometheus / Loki / Tempo
       |                                +-- DeepSeek
       |                                +-- 证据校验 / 降级
       |                                +-- 钉钉群机器人
       |
       +-- severity=critical --> alert-webhook /webhook/critical
       +-- severity=warning  --> alert-webhook /webhook/warning
```

6b 额外增加一段请求链路：

```text
loadgen
  |
  | GET /checkout
  v
log-demo
  |
  | GET /item，客户端超时 2s
  v
inventory.demo:8080
```

关键点：

- `continue: true` 让同一个告警既走原来的本地 webhook，也走 AI 摘要。
- Operator 生成的 receiver 名是 `monitoring/demo-alerting/ai-summary`，并自动加上 `namespace="monitoring"` matcher。
- AI 服务不阻塞 Alertmanager：先 `202`，再在后台采集和调用模型。

对应 Kubernetes 对象：

```text
ConfigMap/ai-summary-app        -> app.py
Deployment/ai-summary           -> 单副本 FastAPI
Service/ai-summary              -> 8080
ServiceMonitor/ai-summary       -> Prometheus 抓取 /metrics
Secret/ai-summary-secrets       -> 三个凭证
AlertmanagerConfig/demo-alerting -> ai-summary receiver + continue 路由

inventory-service.yaml:
ConfigMap/inventory-app         -> server.py
Deployment/inventory            -> 单副本标准库 HTTP 服务
Service/inventory               -> 8080
```

## 3. 证据 ID

采集层把每条证据编号，模型只能引用这些编号：

| ID | 来源 | 查询 | 作用 |
|---|---|---|---|
| `M1` | Prometheus | `demo:error_budget_burn_rate5m` | 5 分钟燃烧率，判断是否 P1 |
| `M1h` | Prometheus | `demo:error_budget_burn_rate1h` | 1 小时燃烧率 |
| `M30m` | Prometheus | `demo:error_budget_burn_rate30m` | 30 分钟燃烧率 |
| `M6h` | Prometheus | `demo:error_budget_burn_rate6h` | 6 小时燃烧率 |
| `M2` | Prometheus | `demo:sli_availability:ratio_rate5m` | 5 分钟可用性 |
| `M3` | Prometheus | 5xx 速率 / 总速率 | 5xx 比例 |
| `M4` | Prometheus | `sum(rate(demo_http_requests_total[5m]))` | 请求速率，识别无流量 |
| `M5` | Prometheus | `topk(3, sum by (path,status) (rate(5xx)))` | 错误路径和状态码 |
| `M6` | Prometheus | `histogram_quantile(0.95, ...)` | P95 延迟 |
| `M7` | Prometheus | `up{namespace="demo"}` | demo target 和 Pod 名 |
| `L1` | Loki | `{namespace="demo"} \| json \| line_format "{{.log}}" \| json \| level="error"` | 最近 15 分钟错误日志和 5 分钟计数 |
| `T1` | Tempo | `{resource.service.name="log-demo" && status=error}` | 最近 15 分钟错误 trace 摘要 |
| `T2` | Tempo | `inventory.call` span 时长 | 下游调用耗时，6b 使用 |

设计取舍：

- Tempo 只取搜索结果的前 2 条 trace，再拉这两条的子 span 摘要，不拉整棵 span 树。目的是控制请求数和 token，不是做全量链路分析。
- 非有限值（`NaN`）视为缺失证据，记录 `error: "nan"`，不渲染成 `nanx` / `nanms`。
- 所有日志和 annotation 先脱敏再进提示词。

## 4. 置信度与优先级

### 4.1 置信度

置信度不是模型自报，而是服务端按“命中的证据源数量”计算：

```text
confidence = round(100 * matched / 3)
matched ∈ {0, 1, 2, 3}
```

| matched | 置信度 | 卡片表现 |
|---:|---:|---|
| 3 | 100% | 正常标题 |
| 2 | 67% | 正常标题 |
| 1 | 33% | 标题加 `[低置信度]`，根因强制为“证据不足” |
| 0 | 0% | 标题加 `[低置信度]`，根因强制为“证据不足” |

各告警的“命中”定义：

| 场景 | 指标命中 | 日志命中 | 链路命中 |
|---|---|---|---|
| FastBurn | `M1 > 14.4` | `L1_COUNT > 0` 或存在错误日志 | 存在错误 span |
| SlowBurn | `M30m > 6` | 同上 | 同上 |
| NoTraffic | `M4 == 0` | 不算命中 | 不算命中 |
| 超时场景 | `M6 > 1s` 或 `M1 > 14.4` | 日志含 `timeout` / `downstream` | `inventory.call > 2000ms` |

超时场景的判定优先于告警名，避免下游超时被套进 500 模板。

### 4.2 优先级

优先级是确定性规则，不交给模型：

```text
DemoNoTraffic                          -> P3
critical 且 M1 > 14.4                  -> P1
其他（含 warning）                      -> P2
```

## 5. 卡片字段

钉钉 markdown 卡片固定包含：

- 严重程度
- 服务 / Pod
- 优先级
- 状态和开始时间（UTC+8）
- 摘要
- 根因分析（带证据编号）
- 影响组件
- 建议操作（最多 3 条）
- 证据（命中数 / 3）
- 置信度和证据来源
- 未知项（如有）

根因由模型生成，但必须满足：

1. `root_cause_evidence` 只能引用真实存在的证据 ID；
2. 引用非法时触发一次修复重试，仍非法则走规则降级；
3. 根因文字必须能在对应证据里找到支撑，不能出现证据外的组件名或技术栈。

## 6. 6a 注入与时间线

注入方式：

```bash
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/error
kubectl -n demo rollout status deploy/demo-loadgen --timeout=180s
```

时间线（`+08:00`）：

| 时间 | 事件 |
|---|---|
| 20:15:13 | 基线：`burn5m=0`，5xx 速率 0，无 `Demo*` active |
| 20:15:31 | loadgen 切到 `/error` |
| 20:26:49 | `DemoAvailabilityFastBurn=active`（约 11 分 18 秒） |
| 20:26:50 | 置信度 `matched=3 / 100%` |
| 20:26:52 | 模型返回，引用 `M3/M5/M2/L1/T1` |
| 20:26:54 | 钉钉收到 `【P1】demo 可用性快速燃烧` |
| 20:35:40 | 轮询首次看到 `FastBurn=none` |
| 20:35:49 | 收到 resolved 通知 |
| 20:35:50 | 钉钉收到 `✅ 已恢复：demo 可用性快速燃烧` |
| 20:35:54 | SlowBurn 触发 P2 卡片（长窗口残留，见已知偏差） |

为什么不是注入后立刻 firing：

- 5m 窗口要等错误填满；
- 1h 窗口也要超过 14.4x；
- 规则还有 `for: 2m`；
- 三者叠加，实测约 9–12 分钟。

## 7. 证据对照

服务端日志：

```text
matched=3  confidence=100
M1=100.0  M30m=37.22222222222222  M4=0.49824561403508766
M6=0.00475  L1_COUNT=149.0
cited = M3, M5, M2, L1, T1
```

手工 PromQL：

```text
M1 => 100
M3 => 1
M5 => {'path': '/error', 'status': '500'} 0.49824561403508766
```

| 证据 | 卡片值 | 手工查询 | 结论 |
|---|---|---|---|
| M1 | 100.0 | 100 | 一致 |
| M3 | 1.0 | 1 | 一致 |
| M5 | `/error` + `500` + 0.49824561403508766 req/s | 同左 | 完全一致 |
| L1 | 149 行 / 5m | Loki 查询 149 | 一致 |
| T1 | 错误 span > 0 | Tempo 有 error trace | 一致 |

根因原文要点：

```text
log-demo 的 /error 路径在 5 分钟内 100% 返回 500（错误率 1.0），
日志持续输出 error 且 trace 显示错误 span，
但证据未揭示 500 的具体触发原因（如代码缺陷或下游依赖）。
```

禁忌词检查：

```text
forbidden = []
```

即没有 `inventory`、`数据库`、`database`、`redis`、`mysql`。

## 8. 6b 下游超时

### 8.1 场景

6b 在 demo 和 inventory 之间加入一条真实调用链：

```text
loadgen -> GET /checkout -> demo -> GET /item (timeout 2s) -> inventory (sleep 5s)
```

inventory 由 `DELAY_MS=5000` 模拟下游变慢；demo 的客户端超时是 2 秒，所以：

- demo 在 2 秒时放弃等待；
- `/checkout` 返回 504；
- 日志写 `downstream timeout`；
- `inventory.call` span 被标记为 ERROR，时长约 2 秒；
- inventory 自己仍然把 5 秒的请求处理完，日志里是 `elapsed_ms≈5000`。

这也是为什么卡片里 `T2=2013ms`，而不是 `5000ms`：T2 记录的是**调用方实际等待时长**，不是下游总处理时长。

### 8.2 注入与时间线

基线（`15:00:03 +08`）：

```text
burn5m=0  P95=0.00475s  请求速率=0.498 req/s  无 Demo* active
```

注入：

```bash
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/checkout
kubectl -n demo rollout status deploy/demo-loadgen --timeout=180s
kubectl -n demo set env deploy/inventory DELAY_MS=5000
kubectl -n demo rollout status deploy/inventory --timeout=180s
```

实际注入时间 `15:00:51`。

| 时间（+08） | 事件 |
|---|---|
| 15:00:51 | 切 `/checkout` 并注入 5 秒延迟 |
| 15:11:09 | FastBurn `startsAt` |
| 15:11:19 | ai-summary 收到告警 |
| 15:11:20 | 置信度 `matched=3 / 100% / timeout=true` |
| 15:11:24 | 钉钉 P1 卡片 |
| 15:11:32 | 轮询看到 FastBurn active |
| 15:22:49 | 收到 resolved |
| 15:22:50 | 钉钉恢复卡片 |
| 15:22:52 | SlowBurn P2 卡片（长窗口残留） |

### 8.3 证据

服务端日志：

```text
matched=3  confidence=100  timeout=true
M1=100.0  M30m=21.41154156691881  M4=0.24912280701754383
M6=2.425  L1_COUNT=75.0
M5=[{'path': '/checkout', 'status': '504', 'value': 0.24912280701754383}]
T2=2013.363098
cited=['M3', 'M5', 'L1', 'T1', 'T2']
```

| 证据 | 6b 值 | 说明 |
|---|---|---|
| M1 | 100.0 | 5m 燃烧率 100x |
| M3 | 1.0 | 5xx 比例 100% |
| M5 | `/checkout` + `504` + 0.249 req/s | 错误路径已切换 |
| M6 | 2.425s | P95 超过 2 秒 |
| T2 | 2013ms | 调用方 2 秒超时 |
| L1 | 75 行 / 5m | `downstream timeout` |
| T1 | 2 个错误 span | `/checkout` 和 `inventory.call` |

根因原文：

```text
log-demo 调用下游 inventory 超时（trace 中 inventory 调用约 2013ms），
导致 /checkout 返回 504、错误率 100%，触发可用性快速燃烧。
```

建议：

```text
1. 检查 inventory 服务健康、延迟与超时配置
2. 核对 log-demo 到 inventory 的网络与连接池状态
3. 必要时对 /checkout 降级或限流以止血
```

未知项明确写出“inventory 侧具体故障原因（无其指标/日志）”，没有把超时进一步编造成网络、过载或依赖故障。

### 8.4 6a / 6b 对比

| 项 | 6a | 6b |
|---|---|---|
| 故障 | `/error` 立即 500 | `/checkout` 调下游超时 |
| M5 路径/状态 | `/error` + `500` | `/checkout` + `504` |
| M6 P95 | `0.00475s` | `2.425s` |
| T2 inventory.call | 无 | `2013ms` |
| 日志 | `demo error for Loki` | `downstream timeout` |
| 根因 | `/error` 100% 500，触发原因证据不足 | inventory 超时导致 504 |
| 证据 | `M3/M5/M2/L1/T1` | `M3/M5/L1/T1/T2` |
| 标题 | P1 / 100% | P1 / 100% |

标题相同是因为两次都是 `DemoAvailabilityFastBurn`；正文的路径、P95、T2、根因和建议不同，满足“可区分”要求。

### 8.5 发现的问题与修复

1. **BrokenPipeError**：loadgen 的 `wget -T 2` 和 demo 的 2 秒下游超时同时到期，客户端先断开，demo 写 504 时触发 `BrokenPipeError`。指标和 `downstream timeout` 日志在断开前已写入，证据有效，但 traceback 淹没了日志。
   - 修复：`demo-loadgen.yaml` 改为 `wget -T 5`，客户端能正常收到 504。
2. **钉钉重复渲染反引号内容**：M5 路径和 T1 trace ID 放在反引号里，钉钉渲染后显示成两份。
   - 修复：`format_evidence_lines` 去掉反引号，M5 改为 `路径（状态码）`。Pod 内验证 `backticks: 0`。
3. **startupProbe 150 秒不够**：`pip install` 从清华源安装超过 150 秒，Pod 被 kubelet 重启 2 次。
   - 修复：`failureThreshold` 从 30 提到 60（300 秒）。新 Pod `RESTARTS=0`。

## 9. 去重、延迟和资源

| 项 | 结果 |
|---|---|
| webhook 响应 | `202`，实测 11.8ms |
| 去重 | Task 2 合成告警重复投递 2 次，命中 `alert_duplicate`，未重复发送 |
| 真实 6a 投递 | 本轮只产生 1 条 `alert_received` |
| 最近 300 行 `alert_duplicate` | 0 |
| `ai-summary` 内存 | 39Mi（最终检查；6a 时为 50Mi） |
| `inventory` 内存 | 14Mi |
| ServiceMonitor | `up{job="ai-summary"}=1` |

去重 key：

```text
groupKey + "|" + 排序后的 alertname 集合
resolved 追加 ":resolved"
```

默认 TTL 600 秒。

## 10. 降级与注入防护

### 10.1 模型不可用

`LLM_ENABLED=0` 或调用失败时：

```text
llm_skipped / llm_error
source: fallback
root_cause: 证据不足，需人工判断（模型未参与）
```

规则模板仍会输出摘要、错误率、错误路径、错误日志和建议操作，钉钉照常收到卡片。

### 10.2 提示词注入

告警 annotation 先过注入正则，命中则替换为 `[FILTERED_UNTRUSTED_INSTRUCTION]`，并记录：

```text
annotation_filtered keys=["description"]
```

模型系统提示词明确要求忽略 `<untrusted_logs>` 内的指令，annotation 只是人类假设，不是证据。

### 10.3 脱敏

进入日志、提示词和卡片前统一处理：

- `Authorization` / `Bearer` / `token` / `password` / `secret` / `api_key`
- `sk-` 开头的 key
- 邮箱、手机号
- 32 位以上十六进制串
- 非 `127.0.0.1` 的 IP

实测 `Authorization: Bearer sk-abcdef123456` → `Authorization=[REDACTED]`。

## 11. 已知限制与偏差

1. **后台任务不持久**：webhook 返回 `202` 后，采集和模型调用在进程内后台任务里执行。Pod 重启会丢失正在处理的告警，没有队列和重试。实验环境接受这个取舍。
2. **无 NetworkPolicy**：`aiops` 可以访问集群内所有 Service。生产应按最小权限限制出口。
3. **SlowBurn 长窗口**：FastBurn 恢复后 SlowBurn 仍会 active。30m/6h 窗口保留了多次故障期的错误，可能持续数小时。这是长窗口 SLO 的正常行为，没有改阈值，也没有用静默掩盖。快照时 SlowBurn 处于 active 是允许的。
4. **邮件兜底未启用**：设计保留邮件通道，实际只验证了钉钉。
5. **钉钉限流合并未压测**：代码在 1 分钟内第 11 条起改为汇总消息，但没有真实制造 10 条/分钟以上的告警来验证。
6. **文档环境差异**：早期文档写 Ubuntu 24.04，实际集群是 22.04.5；本记录按实际值记录。
7. **模型输出有随机性**：同一份证据两次生成的措辞可能不同，但证据 ID、置信度、优先级和数值是确定性的。
8. **Tempo 只取 2 条 trace**：适合快速摘要，不适合统计全量错误分布。
9. **inventory 是模拟服务**：`DELAY_MS` 和 `FAIL_MODE` 通过环境变量控制，修改后需要 rollout；它没有接入 Prometheus ServiceMonitor，所以 6b 的指标证据仍来自 demo。
10. **6b 初始版本的客户端超时与下游超时相同**：loadgen 的 `wget -T 2` 和 demo 的 2 秒超时同时到期，导致 `BrokenPipeError`。已把客户端超时改为 5 秒；首次 6b 的指标和日志仍然有效。
11. **T2 不是下游总处理时长**：`inventory.call` 在调用方超时时就结束，所以 `T2≈2013ms`，而 inventory 日志显示 `elapsed_ms≈5000`。卡片按 T2 写“约 2013ms”，没有夸大成 5 秒。
12. **启动依赖在线安装**：`ai-summary` 启动时从清华源 `pip install`，网络慢会拉长启动时间。已把 startupProbe 放宽到 300 秒，但生产应改为预构建镜像。
13. **钉钉 markdown 兼容性**：行内代码（反引号）在钉钉里会出现重复显示，卡片证据区已改为纯文本。

## 12. 复现命令

```bash
# 服务状态
kubectl -n aiops get deploy,pod,svc,servicemonitor
kubectl -n aiops logs deploy/ai-summary --tail=50
kubectl -n demo get deploy,pod,svc

# 健康检查
kubectl exec -i -n aiops deploy/ai-summary -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/healthz").read())'
kubectl -n demo exec -i deploy/demo-loadgen -- \
  wget -qO- http://inventory.demo.svc.cluster.local:8080/item

# 正常 SLI
kubectl exec -i -n aiops deploy/ai-summary -- python - <<'PY'
import json, urllib.parse, urllib.request
base = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
for q in ("demo:error_budget_burn_rate5m", "demo:sli_availability:ratio_rate5m"):
    url = base + "/api/v1/query?query=" + urllib.parse.quote(q)
    print(q, "=>", json.load(urllib.request.urlopen(url, timeout=5))["data"]["result"])
PY

# 6a 注入
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/error
kubectl -n demo rollout status deploy/demo-loadgen --timeout=180s
date -Is

# 观察卡片
kubectl -n aiops logs deploy/ai-summary --tail=80 | \
  grep -E '"event": "(alert_received|confidence|llm_ok|dingtalk_sent)"' | tail -5

# 6a 恢复
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/
kubectl -n demo rollout status deploy/demo-loadgen --timeout=180s

# 6b 注入
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/checkout
kubectl -n demo rollout status deploy/demo-loadgen --timeout=180s
kubectl -n demo set env deploy/inventory DELAY_MS=5000
kubectl -n demo rollout status deploy/inventory --timeout=180s

# 6b 恢复
kubectl -n demo set env deploy/inventory DELAY_MS=0
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/
kubectl -n demo rollout status deploy/inventory --timeout=180s
kubectl -n demo rollout status deploy/demo-loadgen --timeout=180s
```

## 13. 快照

### 13.1 phase-6a-ai-summary-ready

创建时间：`2026-10-26 21:00:36 +08:00`（记录时的集群时间）。三台 VM（`k8s-server`、`k8s-worker-1`、`k8s-worker-2`）均已创建，用户确认。

快照前状态：

| 项 | 值 |
|---|---|
| 节点 | 三台 `Ready`，k3s `v1.36.5+k3s1` |
| `ai-summary` | `Running`，0 次重启，内存 50Mi |
| `demo-loadgen` | `1/1` |
| `log-demo` | `1/1` |
| `web` | `2/2` |
| `DemoAvailabilitySlowBurn` | 仍 active（30m/6h 长窗口残留，预期） |

### 13.2 phase-6-ai-summary-ready

创建时间：`2026-10-28`（用户确认；未单独记录秒级时间）。三台 VM（`k8s-server`、`k8s-worker-1`、`k8s-worker-2`）均已创建。

快照前状态：

| 项 | 值 |
|---|---|
| 节点 | 三台 `Ready`，k3s `v1.36.5+k3s1` |
| `ai-summary` | `Running`，0 次重启，内存 39Mi |
| `inventory` | `Running`，内存 14Mi |
| `demo-loadgen` | `1/1`，`TARGET_PATH=/` |
| `log-demo` | `1/1` |
| `web` | `2/2` |
| 非 Running Pod | 无 |
| 注入参数 | `inventory DELAY_MS=0`，`FAIL_MODE=0` |

该快照包含：

- 6a 的证据采集、置信度、降级和卡片；
- 6b 的 `inventory` 服务、`/checkout` 和 `inventory.call` span；
- 卡片反引号修复（M5 带状态码、T1 不重复）；
- loadgen 客户端超时 5 秒；
- startupProbe 300 秒。

重启验证：三节点 `Ready`，所有 Pod `Running`，`/item`、`/checkout`、`/healthz` 均正常（用户确认）。容器 RESTARTS 增加是节点重启后的正常现象。

## 14. 结论

6a 和 6b 的核心链路均已打通：

```text
真实故障
  -> FastBurn firing
  -> Alertmanager continue 路由
  -> ai-summary 202 + 后台处理
  -> Prometheus / Loki / Tempo 证据
  -> DeepSeek 归纳 + 服务端证据校验
  -> 钉钉 P1 卡片
  -> 恢复后 resolved 卡片
```

可以确认：

- 6a 的 `/error` 500 卡片与手工 PromQL 逐项一致；
- 6b 的 `/checkout` 504 卡片指出 inventory 下游超时，证据含 M6、L1、T1、T2；
- 同一套采集和提示词，在 6a/6b 得到不同根因、不同建议；
- 置信度、优先级不依赖模型自报；
- 无证据时不会编造组件和技术栈；
- 模型关闭或失败时仍能发出降级卡片；
- 重复投递被去重，webhook 不阻塞 Alertmanager；
- 最终快照保留 6a 和 6b 两个可回滚节点。

下一步：阶段 7 受控运维，重点是只读权限、分级审批和审计，而不是让模型直接执行动作。
