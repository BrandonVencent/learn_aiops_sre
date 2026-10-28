# 阶段 0–6 已实现能力总览

> 更新时间：2026-10-28
> 对应快照：`phase-6a-ai-summary-ready`、`phase-6-ai-summary-ready`
> 用途：一页回答三个问题——现在到底能跑什么、验证到什么程度、还缺什么。
> 本文只记录能力、配置和验证结果，不包含 DeepSeek API key、钉钉 webhook、加签 SEC 或任何密码。

## 0. 一句话总结

一条「故障发生 → SLO 告警 → AI 采集指标/日志/链路证据 → 生成钉钉卡片」的链路已经跑通，并用两种不同的真实故障验证过。

系统目前**只读**：能看、能查、能解释，但不能重启、回滚、扩缩容。写操作留给阶段 7。

## 1. 环境基线

| 项 | 值 |
|---|---|
| 宿主机 | Windows，16 GB 内存，14 核 20 线程 |
| 虚拟化 | VMware Workstation，`VMnet8`，`172.25.254.0/24` |
| 节点 | `k8s-server` 4C/6GB，`k8s-worker-1` 2C/3GB，`k8s-worker-2` 2C/3GB |
| 系统 | Ubuntu Server 22.04.5 LTS |
| 集群 | k3s `v1.36.5+k3s1` |
| Helm | `v3.22.1` |
| 命名空间 | `demo`、`monitoring`、`logging`、`tracing`、`aiops` |
| 资源约束 | `demo` / `aiops` 各有 LimitRange；`demo` 配额 `requests 2C/2Gi`、`limits 4C/4Gi`、`pods 20` |

## 2. 分层能力

### 2.1 集群底座（阶段 0–1）

- 三节点 k3s，控制面与工作负载分离，跨节点调度正常。
- 命名空间隔离，`demo` 与监控栈互不混放。
- LimitRange 给未声明资源的 Pod 兜底，避免单 Pod 吃满节点。
- ResourceQuota 限制 `demo` 的 CPU、内存和 Pod 数量。
- 提供建集群、加入节点、导出 kubeconfig、资源基线脚本。
- 冒烟测试覆盖 Pod 调度、Service 访问、跨节点网络。

对应文件：

- [`infra/manifests/00-namespaces.yaml`](../../infra/manifests/00-namespaces.yaml)
- [`infra/manifests/01-limitrange.yaml`](../../infra/manifests/01-limitrange.yaml)
- [`infra/manifests/02-resourcequota.yaml`](../../infra/manifests/02-resourcequota.yaml)
- [`infra/manifests/smoke-test.yaml`](../../infra/manifests/smoke-test.yaml)
- [`infra/scripts/`](../../infra/scripts)

### 2.2 指标链路（阶段 2）

- `kube-prometheus-stack 92.11.0`：Prometheus、Grafana、Alertmanager、kube-state-metrics、node-exporter、Prometheus Operator。
- Prometheus 抓取三类目标：节点、K8s 对象、自写 demo 的 `/metrics`。
- Grafana 通过 NodePort `30030` 访问，Prometheus `30090`，Alertmanager `30093`。
- 实际做过重启计数实验：`kube_pod_container_status_restarts_total` 随重启增长，确认指标口径可用。
- 能回答「哪个 Pod 在吃 CPU」「哪个 Pod 重启过」「节点还剩多少内存」。

对应文件：

- [`infra/monitoring/values-kube-prometheus-stack.yaml`](../../infra/monitoring/values-kube-prometheus-stack.yaml)
- [`infra/alerting/demo-servicemonitor.yaml`](../../infra/alerting/demo-servicemonitor.yaml)
- [阶段 2 验收记录](02-phase-2-acceptance.md)、[values 解释](03-monitoring-values-explained.md)

### 2.3 日志链路（阶段 3）

- `loki-19.0.3`（应用 `3.7.9`）+ `fluent-bit-0.58.3`（应用 `5.1.3`），DaemonSet 每节点一个。
- demo 输出结构化 JSON 日志，字段含 `level`、`message`、`trace_id`、`span_id`。
- Fluent Bit 配置了 Python traceback 的多行合并，避免一条异常被拆成十几行。
- Grafana Loki 数据源带 derived field：`trace_id` 可直接跳到 Tempo。
- 能按 `namespace`、`pod`、`level` 过滤，也能用 LogQL 统计错误条数。

对应文件：

- [`infra/logging/values-loki.yaml`](../../infra/logging/values-loki.yaml)
- [`infra/logging/values-fluent-bit.yaml`](../../infra/logging/values-fluent-bit.yaml)
- [`infra/logging/grafana-loki-datasource.yaml`](../../infra/logging/grafana-loki-datasource.yaml)
- [阶段 3 验收记录](03-phase-3-acceptance.md)、[values 解释](04-logging-values-explained.md)

### 2.4 链路追踪（阶段 4）

- Tempo `tempo-3.2.1`（应用 `3.1.1`）+ OTel Collector `0.163.2`。
- demo 通过 OTel SDK 打点，`/`、`/error`、`/checkout` 都有 server span。
- 一次请求能看到完整 span 树，错误 span 状态为 `ERROR`。
- 日志与链路双向跳转：日志里的 `trace_id` 打开 trace，span 上的 **Related logs** 回到同一时间窗的日志。
- Collector exporter 使用 `otlp_grpc`，避免 `otlp` 别名在 0.163.2 中不可用的问题。

对应文件：

- [`infra/tracing/values-tempo.yaml`](../../infra/tracing/values-tempo.yaml)
- [`infra/tracing/otel-collector.yaml`](../../infra/tracing/otel-collector.yaml)
- [`infra/tracing/demo-service-otel.yaml`](../../infra/tracing/demo-service-otel.yaml)
- [阶段 4 验收记录](04-phase-4-acceptance.md)、[values 解释](05-tracing-values-explained.md)

### 2.5 告警与 SLO（阶段 5）

- 基于 demo 的可用性定义 SLI，用 recording rule 预计算，AI 查询与人工查询同口径。
- 三组多窗口燃烧率告警：

| 告警 | 窗口 | 阈值 | 用途 |
|---|---|---|---|
| `DemoAvailabilityFastBurn` | 5m / 1h | 14.4 倍 | 快速失血，P1 |
| `DemoAvailabilitySlowBurn` | 30m / 6h | 6 倍 | 慢性劣化，P2 |
| `DemoNoTraffic` | 10m | 无请求 | 探针/链路中断 |

- Alertmanager 完成路由、分组、抑制、静默配置。
- 本地 `alert-webhook` 分 `/webhook/critical` 和 `/webhook/warning`，保留原始通知链路。
- `AlertmanagerConfig` 增加 `ai-summary` receiver，并用 `continue: true` 让告警同时走两条路。

对应文件：

- [`infra/alerting/demo-slo-rules.yaml`](../../infra/alerting/demo-slo-rules.yaml)
- [`infra/alerting/alertmanager-config.yaml`](../../infra/alerting/alertmanager-config.yaml)
- [`infra/alerting/alert-webhook.yaml`](../../infra/alerting/alert-webhook.yaml)
- [阶段 5 验收记录](06-phase-5-acceptance.md)、[values 解释](07-alerting-values-explained.md)

### 2.6 AI 告警摘要（阶段 6）

#### 2.6.1 服务接口

| 路径 | 行为 |
|---|---|
| `POST /webhook/alert` | 校验后立即返回 `202`（实测 11.8ms），采集与模型调用在后台线程执行 |
| `GET /healthz` | 返回 `{"status":"ok"}`，供 liveness/readiness/startup 探针 |
| `GET /metrics` | 暴露 `ai_summary_*` 指标，由 ServiceMonitor 抓取 |

- 单副本 FastAPI，`python:3.12-slim`，内存实测 39Mi（limit 384Mi）。
- startupProbe 给 300 秒，覆盖清华源 `pip install` 偶发变慢的情况。

#### 2.6.2 证据集

| ID | 来源 | 内容 |
|---|---|---|
| M1 / M1h / M30m / M6h | Prometheus | 各窗口错误预算燃烧率 |
| M2 | Prometheus | 请求速率 |
| M3 | Prometheus | 5xx 比例 |
| M4 | Prometheus | 错误预算剩余 |
| M5 | Prometheus | 错误路径 + 状态码 + 速率 |
| M6 | Prometheus | P95 延迟 |
| M7 | Prometheus | target `up` 与 Pod 名 |
| L1 / L1_COUNT | Loki | 错误日志样本与 5 分钟内条数 |
| T1 | Tempo | 错误 trace 摘要与错误 span 数，最多 2 条 |
| T2 | Tempo | `inventory.call` 子 span 时长 |

- Loki 查询做了双重 JSON 解包：Fluent Bit 的 `log` 字段里还是 JSON，需要 `| json | line_format "{{.log}}" | json`。
- 非有限值（`NaN`、`Inf`）在采集层就被过滤，不会进入卡片。

#### 2.6.3 置信度与优先级

- 置信度由服务端按证据源覆盖计算，不采信模型自报：

| 命中的证据源 | 置信度 | 卡片表现 |
|---|---|---|
| 3 个（指标 + 日志 + 链路） | 100% | 正常 |
| 2 个 | 67% | 正常，标注覆盖不足 |
| 1 个 | 33% | 加 `[低置信度]` |
| 0 个 | 0% | 强制「证据不足」，不输出根因 |

- 优先级是确定性规则：`NoTraffic` → P3；critical 且 `burn5m > 14.4` → P1；其余 P2。
- 超时场景单独判定：先看 trace/日志是否指向下游，再决定指标命中规则，避免 6a/6b 互相套模板。

#### 2.6.4 安全与降级

- 脱敏：`Authorization`、`Bearer`、`token`、`password`、`secret`、`api_key`、`sk-` 前缀、邮箱、手机号、32 位以上十六进制串、非本机 IP。
- 提示词注入：annotation 命中指令性正则后替换为 `[FILTERED_UNTRUSTED_INSTRUCTION]`，日志记录被过滤的 key。
- 系统提示词明确声明 annotation 只是人类假设，不是证据；`<untrusted_logs>` 内的指令一律忽略。
- 证据校验：模型引用的 ID 必须真实存在，根因不能出现无证据组件（如 6a 卡片禁止出现 `inventory`、数据库、Redis）。
- 降级：`LLM_ENABLED=0` 或模型调用失败时，用规则模板发卡片，仍然带证据和优先级。
- 去重：10 分钟窗口内相同指纹只处理一次，重复投递记 `alert_duplicate`，不重复调模型、不重复发钉钉。

#### 2.6.5 钉钉通知

- 群机器人加签发送，实测 `errcode=0`。
- 卡片字段：严重程度、服务/Pod、根因分析、影响组件、建议操作、优先级、置信度。
- 卡片证据区用纯文本，不使用反引号——钉钉 markdown 会把行内代码内容重复渲染。
- 恢复时发送 ✅ 已恢复卡片。
- 1 分钟内超过 10 条时改为汇总消息（代码已实现，未做真实压测）。

对应文件：

- [`infra/aiops/ai-summary.yaml`](../../infra/aiops/ai-summary.yaml)
- [`infra/aiops/ai-summary-servicemonitor.yaml`](../../infra/aiops/ai-summary-servicemonitor.yaml)
- [`infra/aiops/inventory-service.yaml`](../../infra/aiops/inventory-service.yaml)
- [阶段 6 验收记录](08-phase-6-acceptance.md)、[解释](09-ai-summary-explained.md)

## 3. 两次真实验收

### 3.1 6a：`/error` 立即 500

```text
注入 TARGET_PATH=/error
  -> FastBurn firing
  -> ai-summary 202 + 后台处理
  -> 钉钉 P1 / 100%
  -> 根因：/error 路径 100% 500，具体触发原因证据不足
```

| 证据 | 值 |
|---|---|
| M1 | 100.0 |
| M3 | 1.0 |
| M5 | `/error` + `500` + 0.498 req/s |
| M6 | 0.00475s |
| L1 | 149 行 |
| T1 | 有错误 span |

卡片与手工 PromQL 逐项一致，且没有出现任何无证据组件。

### 3.2 6b：`/checkout` 下游超时

```text
loadgen -> /checkout -> demo --(2s timeout)--> inventory (sleep 5s)

注入 TARGET_PATH=/checkout + DELAY_MS=5000
  -> FastBurn firing
  -> 钉钉 P1 / 100%
  -> 根因：调用 inventory 超时，/checkout 返回 504
```

| 证据 | 值 |
|---|---|
| M1 | 100.0 |
| M3 | 1.0 |
| M5 | `/checkout` + `504` + 0.249 req/s |
| M6 | 2.425s |
| T2 | 2013ms |
| L1 | 75 行 `downstream timeout` |

`T2` 是调用方等待时长，不是 inventory 自己的 5 秒处理时长；卡片按 2013ms 写，没有夸大成 5 秒。

### 3.3 6a / 6b 对比

| 项 | 6a | 6b |
|---|---|---|
| 故障类型 | 自身立即失败 | 下游变慢导致超时 |
| M5 | `/error` 500 | `/checkout` 504 |
| M6 P95 | 4.75ms | 2425ms |
| T2 | 无 | 2013ms |
| 日志 | `demo error for Loki` | `downstream timeout` |
| 根因 | 自身 500，触发原因未知 | 下游 inventory 超时 |
| 证据集 | M3/M5/M2/L1/T1 | M3/M5/L1/T1/T2 |

标题相同（都是 `DemoAvailabilityFastBurn`），但正文的路径、延迟、trace 和根因不同，可以区分。

## 4. 端到端演示路径

```text
kubectl -n demo set env deploy/demo-loadgen TARGET_PATH=/error
        |
        | 约 11 分钟（5m 窗口 + for 2m + 轮询）
        v
DemoAvailabilityFastBurn firing
        |
        v
Alertmanager --continue:true--> ai-summary 202
        |                          |
        |                          +-> Prometheus / Loki / Tempo
        |                          +-> 证据校验 + DeepSeek
        |                          +-> 置信度 / 优先级
        |                          +-> 钉钉卡片
        v
原 alert-webhook 照常收到
```

恢复时把 `TARGET_PATH` 改回 `/`，FastBurn resolved，钉钉收到恢复卡片。

## 5. 验收证据索引

| 能力 | 关键证据 | 文档 |
|---|---|---|
| 集群与隔离 | 三节点 Ready、跨节点调度、配额生效 | [阶段 0–1](01-phase-0-1-acceptance.md) |
| 指标 | `up=1`、重启计数增长、PromQL 结果 | [阶段 2](02-phase-2-acceptance.md) |
| 日志 | Loki 查询命中、traceback 合并为一条 | [阶段 3](03-phase-3-acceptance.md) |
| 链路 | span 树、错误 span、双向跳转 | [阶段 4](04-phase-4-acceptance.md) |
| 告警 | FastBurn firing → resolved、webhook 收件 | [阶段 5](06-phase-5-acceptance.md) |
| AI 摘要 | 6a/6b 卡片、证据逐项对照、降级与注入测试 | [阶段 6](08-phase-6-acceptance.md) |
| 日常问答 | 每日排错记录与命令 | [QA 索引](../03-qa/00-qa-log.md) |

## 6. 未实现与已知限制

### 6.1 阶段 7–8 范围内

- 没有任何写操作：restart、rollback、scale、delete 均未实现。
- 没有只读/执行两种 ServiceAccount，也没有越权验证。
- 没有人工审批、动作 dry-run、审计日志。
- K8s Events 还没进入证据集。
- 没有 Chaos Mesh，故障靠 `set env` 手工注入。
- 没有 postmortem 模板与演练记录。

### 6.2 工程化欠缺

- 无 Ingress/TLS，`ai-summary` 只在集群内可达。
- webhook 无鉴权，能访问 Service 的 Pod 都能触发。
- 后台任务在进程内，Pod 重启会丢正在处理的告警，没有队列和重试。
- 单副本，去重状态在内存，多副本会失效。
- 启动时在线 `pip install`，没有预构建镜像。
- 没有 CI、没有自动化测试目录，YAML 靠人工 `kubectl apply`。
- 卡片与审计没有持久化存储。
- 邮件兜底未启用，钉钉限流合并未压测。

### 6.3 已知偏差

- `SlowBurn` 在 FastBurn 恢复后仍可能 active 数小时，这是 30m/6h 长窗口的正常行为，未用静默掩盖。
- 模型输出措辞有随机性，但证据 ID、数值、置信度、优先级是确定性的。
- Tempo 每次只取 2 条 trace，不能据此得出比例类结论。

## 7. 文件索引

| 层 | 清单 | 说明文档 |
|---|---|---|
| 底座 | [`infra/manifests/`](../../infra/manifests) | [阶段 0–1](01-phase-0-1-acceptance.md) |
| 指标 | [`infra/monitoring/`](../../infra/monitoring)、[`infra/alerting/demo-servicemonitor.yaml`](../../infra/alerting/demo-servicemonitor.yaml) | [阶段 2](02-phase-2-acceptance.md)、[解释](03-monitoring-values-explained.md) |
| 日志 | [`infra/logging/`](../../infra/logging) | [阶段 3](03-phase-3-acceptance.md)、[解释](04-logging-values-explained.md) |
| 链路 | [`infra/tracing/`](../../infra/tracing) | [阶段 4](04-phase-4-acceptance.md)、[解释](05-tracing-values-explained.md) |
| 告警 | [`infra/alerting/`](../../infra/alerting) | [阶段 5](06-phase-5-acceptance.md)、[解释](07-alerting-values-explained.md) |
| AI 摘要 | [`infra/aiops/`](../../infra/aiops) | [阶段 6](08-phase-6-acceptance.md)、[解释](09-ai-summary-explained.md) |
