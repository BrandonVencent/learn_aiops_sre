# 学习问答记录索引

> 约定：每天一个文件，文件名使用 `YYYY-MM-DD.md`；当天的新问题追加到当天文件，不再把所有内容堆到一个文件里。
> 命令保留可复制形式；不记录 token、密码、私钥等敏感信息。
> 每天的文件建议包含：今日进度、真实问题与结论、验证命令、未完成项和下一步。
> 从 2026-10-22 起，新增或修改 YAML 时，先解释对象类型、字段作用、数据流、不写或写错的后果、常见错误，再执行。

## 每日记录

| 日期 | 内容 | 文件 |
|---|---|---|
| 2026-10-21 | 阶段 0–2：k3s 基线、冒烟测试、LimitRange/Quota、kube-prometheus-stack、Grafana OOM | [2026-10-21.md](2026-10-21.md) |
| 2026-10-22 | 阶段 3：Loki + Fluent Bit + Grafana 日志链路、level 查询、Python traceback 多行合并、验收记录与 `phase-3-logging-ready` 快照 | [2026-10-22.md](2026-10-22.md) |
| 2026-10-23 | 阶段 4–5：Tempo/OTel 链路；SLI/SLO、燃烧率告警、Alertmanager 路由/分组/抑制/静默、本地 webhook；SlowBurn 长窗口偏差 | [2026-10-23.md](2026-10-23.md) |

## 记录模板

````markdown
# YYYY-MM-DD 学习问答记录

> 返回：[学习问答记录索引](00-qa-log.md)
> 环境：...
> 约定：...

## 今日进度

- ...

## Q&A

### 1. 问题标题

#### 问题

...

#### 结论

...

#### 验证

```bash
...
```

## 未完成 / 下一步

- ...
````

## 相关文档

- [仓库阅读顺序](../README.md)
- [阶段 3 日志链路计划](../superpowers/plans/phase-3-logging-pipeline.md)
- [阶段 4 链路追踪计划](../superpowers/plans/phase-4-tracing-pipeline.md)
- [阶段 5 告警与 SLO 计划](../superpowers/plans/phase-5-alerting-slo.md)
