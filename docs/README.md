# AIOps / SRE 学习仓库

这个仓库记录一条从「原理」到「实验」的路径：先搞清楚生产环境的可观测性数据是怎么流动的，再在 Windows + VMware 的 Linux 虚拟机上搭一套同构的最小系统，最后把 AI 接到告警和排障环节。

> 目标不是背工具名，而是能画出一条数据从产生到被 AI 使用的完整路径，并解释每一跳为什么存在。

## 阅读顺序

1. [思维导图](01-principles/00-mindmap.md) —— 先建立全局地图
2. [可观测性数据流](01-principles/01-observability-dataflow.md) —— 指标、日志、链路、事件四条线
3. [AI 接入层](01-principles/02-aiops-ai-layer.md) —— RAG、告警增强、根因辅助、受控执行
4. [生产环境与实验环境的差异](01-principles/03-production-vs-lab.md) —— 哪些能模拟，哪些不能
5. [实验设计](02-lab/00-lab-design.md) —— VMware + Linux + K8s 的分阶段搭建方案

## 学习路线

| 阶段 | 目标 | 产出 | 验收方式 |
|---|---|---|---|
| M1 | 集群底座 | 3 节点 K8s，能部署 Pod、看事件 | 能解释 Pod 从创建到 Running 经过哪些组件 |
| M2 | 指标链路 | Prometheus + Grafana + node-exporter + kube-state-metrics | 能用 PromQL 查出「哪个 Pod 在吃 CPU」 |
| M3 | 日志链路 | Fluent Bit → Loki → Grafana | 能追一条日志从 stdout 到查询结果 |
| M4 | 链路追踪 | OTel Collector + Tempo + demo 服务 | 能用 trace_id 把日志和链路串起来 |
| M5 | 告警与 SLO | Alertmanager + SLO 规则 + 通知 | 能解释一次告警从触发到送达的路径 |
| M6 | AI 告警摘要 | Webhook 服务 + 上下文聚合 + LLM | 输出带证据的故障摘要，而不是空泛结论 |
| M7 | 受控运维 | 只读 Agent → 审批 → 低风险动作 | 能说清楚权限、审计、回滚怎么设计 |
| M8 | 故障演练 | 注入故障 + 复盘 | 能写出一份像样的 postmortem |

## 实验环境约定

- 宿主机：Windows，16 GB 内存，14 核 20 线程
- 虚拟化：VMware Workstation，NAT 网络
- 虚拟机：Ubuntu Server 24.04 LTS × 3
- 内存分配：server 6 GB + worker 2 GB × 2，合计 10 GB
- 集群：k3s 三节点（控制面轻，适合 16 GB 宿主机）
- 所有实验都围绕一个自写的 demo 服务展开，它同时提供 `/metrics`、结构化日志、健康检查和故障开关

## 一个贯穿全文的例子

假设用户在电商系统下单失败。生产里发生的事是：

1. 应用把错误写进 stdout，同时暴露 `http_requests_total{code="500"}` 指标
2. 日志被节点上的 Fluent Bit 采集，补上 namespace/pod/node 标签，送进 Loki
3. Prometheus 每 15 秒抓一次指标，触发错误率告警
4. Alertmanager 聚合后发给值班人，同时 webhook 给 AI 分析服务
5. AI 服务按告警时间窗口拉取相关日志、指标、最近发布记录和 K8s 事件
6. LLM 生成「现象 + 证据 + 可能原因 + 建议先查什么」
7. 人确认后，才允许执行重启或回滚这类低风险动作

后面每一章都在拆解这条链路上的一个环节。
