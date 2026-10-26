# 阶段 6 AI 告警摘要验收记录

> 状态：6a（现有 `/error` 500 场景）验收通过；6b（下游超时场景）见文末，完成前本节只记录 6a。
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
- [ ] 三台 VM 创建 `phase-6a-ai-summary-ready` 快照（创建后回填时间）

## 1. 目标与边界

阶段 6a 要回答的问题是：

> 当一条 SLO 告警真的响起时，服务能不能在几十秒内给出“发生了什么、证据是什么、先查哪里”，而不是复述告警标题？

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

## 8. 去重、延迟和资源

| 项 | 结果 |
|---|---|
| webhook 响应 | `202`，实测 11.8ms |
| 去重 | Task 2 合成告警重复投递 2 次，命中 `alert_duplicate`，未重复发送 |
| 真实 6a 投递 | 本轮只产生 1 条 `alert_received` |
| 最近 300 行 `alert_duplicate` | 0 |
| `ai-summary` 内存 | 50Mi |
| ServiceMonitor | `up{job="ai-summary"}=1` |

去重 key：

```text
groupKey + "|" + 排序后的 alertname 集合
resolved 追加 ":resolved"
```

默认 TTL 600 秒。

## 9. 降级与注入防护

### 9.1 模型不可用

`LLM_ENABLED=0` 或调用失败时：

```text
llm_skipped / llm_error
source: fallback
root_cause: 证据不足，需人工判断（模型未参与）
```

规则模板仍会输出摘要、错误率、错误路径、错误日志和建议操作，钉钉照常收到卡片。

### 9.2 提示词注入

告警 annotation 先过注入正则，命中则替换为 `[FILTERED_UNTRUSTED_INSTRUCTION]`，并记录：

```text
annotation_filtered keys=["description"]
```

模型系统提示词明确要求忽略 `<untrusted_logs>` 内的指令，annotation 只是人类假设，不是证据。

### 9.3 脱敏

进入日志、提示词和卡片前统一处理：

- `Authorization` / `Bearer` / `token` / `password` / `secret` / `api_key`
- `sk-` 开头的 key
- 邮箱、手机号
- 32 位以上十六进制串
- 非 `127.0.0.1` 的 IP

实测 `Authorization: Bearer sk-abcdef123456` → `Authorization=[REDACTED]`。

## 10. 已知限制与偏差

1. **后台任务不持久**：webhook 返回 `202` 后，采集和模型调用在进程内后台任务里执行。Pod 重启会丢失正在处理的告警，没有队列和重试。实验环境接受这个取舍。
2. **无 NetworkPolicy**：`aiops` 可以访问集群内所有 Service。生产应按最小权限限制出口。
3. **SlowBurn 长窗口**：FastBurn 恢复后 SlowBurn 仍会 active。30m/6h 窗口保留了多次故障期的错误，可能持续数小时。这是长窗口 SLO 的正常行为，没有改阈值，也没有用静默掩盖。快照时 SlowBurn 处于 active 是允许的。
4. **邮件兜底未启用**：设计保留邮件通道，实际只验证了钉钉。
5. **钉钉限流合并未压测**：代码在 1 分钟内第 11 条起改为汇总消息，但没有真实制造 10 条/分钟以上的告警来验证。
6. **文档环境差异**：早期文档写 Ubuntu 24.04，实际集群是 22.04.5；本记录按实际值记录。
7. **模型输出有随机性**：同一份证据两次生成的措辞可能不同，但证据 ID、置信度、优先级和数值是确定性的。
8. **Tempo 只取 2 条 trace**：适合快速摘要，不适合统计全量错误分布。

## 11. 复现命令

```bash
# 服务状态
kubectl -n aiops get deploy,pod,svc,servicemonitor
kubectl -n aiops logs deploy/ai-summary --tail=50

# 健康检查
kubectl exec -i -n aiops deploy/ai-summary -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/healthz").read())'

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

# 恢复
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/
kubectl -n demo rollout status deploy/demo-loadgen --timeout=180s
```

## 12. 快照

名称：

```text
phase-6a-ai-summary-ready
```

创建时 `ai-summary` 内存 50Mi，SlowBurn 处于 active。创建时间和重启验证结果在创建后回填。

## 13. 结论

6a 的核心链路已经打通：

```text
真实 500
  -> FastBurn firing
  -> Alertmanager continue 路由
  -> ai-summary 202 + 后台处理
  -> Prometheus / Loki / Tempo 证据
  -> DeepSeek 归纳 + 服务端证据校验
  -> 钉钉 P1 卡片
  -> 恢复后 resolved 卡片
```

可以确认：

- 卡片里的关键数值与手工查询逐项一致；
- 置信度、优先级不依赖模型自报；
- 无证据时不会编造组件和技术栈；
- 模型关闭或失败时仍能发出降级卡片；
- 重复投递被去重，webhook 不阻塞 Alertmanager。

下一步：Task 9–11 增加 `inventory` 下游服务和 `/checkout`，构造 6b 超时场景，验证“同一套采集能否得出不同根因”。
