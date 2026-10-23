# 阶段 4 链路追踪验收记录

> 状态：验收通过；三台 VM 已创建 `phase-4-tracing-ready` 快照。
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
| 容器运行时 | `containerd://2.3.4-k3s1.36` |
| Helm | `v3.22.1` |
| 追踪命名空间 | `tracing` |
| Tempo chart / 应用 | `tempo-3.2.1` / `3.1.1` |
| Tempo 镜像 | `docker.io/grafana/tempo:3.1.1` |
| Collector | `otel/opentelemetry-collector-contrib:0.163.2` |
| OpenTelemetry Python | `opentelemetry-sdk==1.45.1`、`opentelemetry-exporter-otlp-proto-http==1.45.1` |
| Grafana | `kube-prometheus-stack-92.11.0`，NodePort `30030` |
| Tempo values | [`infra/tracing/values-tempo.yaml`](../../infra/tracing/values-tempo.yaml) |
| Collector 清单 | [`infra/tracing/otel-collector.yaml`](../../infra/tracing/otel-collector.yaml) |
| demo 清单 | [`infra/tracing/demo-service-otel.yaml`](../../infra/tracing/demo-service-otel.yaml) |
| Grafana 数据源 | [`infra/logging/grafana-loki-datasource.yaml`](../../infra/logging/grafana-loki-datasource.yaml)、[`infra/tracing/grafana-tempo-datasource.yaml`](../../infra/tracing/grafana-tempo-datasource.yaml) |

## 验收清单

- [x] Tempo Helm release `tempo` 部署成功，`REVISION 1`、`STATUS deployed`
- [x] `tempo-0` 为 `1/1 Running`，运行在 `k8s-server`
- [x] PVC `storage-tempo-0` 为 `Bound`，`5Gi`、`local-path`
- [x] Tempo `/ready` 返回 `ready`
- [x] Collector Deployment `otel-collector` 为 `1/1 Running`，运行在 `k8s-worker-1`
- [x] Collector Service 暴露 OTLP gRPC `4317` 和 OTLP HTTP `4318`
- [x] Collector 日志出现 `Everything is ready. Begin running and processing data.`
- [x] Collector exporter 使用 `otlp_grpc`，没有 `otlp` 别名弃用警告
- [x] demo 日志包含 32 位 `trace_id` 和 16 位 `span_id`
- [x] readiness probe 使用 `/healthz`，不再每 5 秒生成日志和 trace
- [x] Tempo 能看到 info trace：`GET /` + `demo.hello`
- [x] Tempo 能看到 error trace：`GET /error` + `demo.fail`，状态为 error
- [x] Loki 的 `TraceID` derived field 能跳到 Tempo
- [x] Tempo 的 `Related logs` 能回到 Loki，并自动带上同一个 `trace_id`
- [x] Grafana 数据源 `Loki` UID `loki`、`Tempo` UID `tempo`
- [x] 资源占用在 16 GB 实验环境可接受
- [x] 三台 VM 创建 `phase-4-tracing-ready` 快照

## 1. 部署结果

### Helm release

```text
NAME    NAMESPACE   REVISION   STATUS     CHART          APP VERSION
tempo   tracing     1          deployed   tempo-3.2.1    3.1.1
```

### Pod、PVC、Service

| 对象 | 值 |
|---|---|
| Tempo Pod | `tempo-0`，`1/1 Running`，`k8s-server` |
| Tempo PVC | `storage-tempo-0`，`5Gi`，`Bound`，`local-path` |
| Tempo Service | `tempo`，`3200`、`4317`、`4318` 等端口 |
| Collector Pod | `otel-collector-79487b5d6d-8m5gr`，`1/1 Running`，`k8s-worker-1` |
| Collector Service | `otel-collector`，ClusterIP，`4317`、`4318` |
| demo Pod | `log-demo-998849ff9-qxksv`，`1/1 Running`，`k8s-worker-2` |
| demo Service | `log-demo`，ClusterIP，`8080` |

Tempo 和 Collector 都没有 NodePort；Grafana 通过集群内 Service 访问它们。

## 2. 数据流

```text
demo 应用（OpenTelemetry Python SDK）
        |
        | OTLP/HTTP :4318/v1/traces
        v
OTel Collector（tracing 命名空间，k8s-worker-1）
        |
        | OTLP/gRPC :4317
        v
Tempo（tracing 命名空间，k8s-server，文件系统 + PVC）
        |
        v
Grafana Tempo 数据源
        |
        +---- Loki 日志里的 TraceID 链接
        |
        v
Loki <---- Tempo 的 Related logs 查询
```

日志链路保持阶段 3 的结构：

```text
demo stdout -> Fluent Bit -> Loki -> Grafana / LogQL
```

两条链路通过同一个 32 位 `trace_id` 关联。

## 3. trace 验收

### 3.1 info trace

日志中的 trace ID：

```text
651bd0d1467a24fcc112b750f88f0027
```

Tempo API 返回的 span 树：

```text
TRACE 651bd0d1467a24fcc112b750f88f0027
  demo.hello {}
  GET / {}
```

说明：

- 根 span 是 `GET /`，类型为 SERVER。
- 子 span 是 `demo.hello`，类型为 INTERNAL。
- HTTP 状态码为 `200`。
- `service.name` 为 `log-demo`。

### 3.2 error trace

Grafana 从 Loki error 日志跳到 Tempo 后看到的 trace ID：

```text
fada9c248ccea6ea3f7525787bd888af
```

Tempo API 返回的 span 树：

```text
TRACE fada9c248ccea6ea3f7525787bd888af
  GET /error {'message': 'demo error for Loki', 'code': 'STATUS_CODE_ERROR'}
  demo.fail {'message': 'demo error for Loki', 'code': 'STATUS_CODE_ERROR'}
```

说明：

- 根 span 是 `GET /error`，HTTP 状态码 `500`。
- 子 span 是 `demo.fail`。
- 两个 span 都是 `STATUS_CODE_ERROR`。
- 子 span 记录了 exception 事件。

## 4. Loki 与 Tempo 的关联

### 4.1 Loki 日志行

Loki 保存的是 Fluent Bit 外层 JSON，应用 JSON 在 `log` 字段里：

```json
{"_p":"F","log":"{\"ts\": \"2026-10-23T09:07:02.999340+00:00\", \"level\": \"error\", \"service\": \"log-demo\", \"trace_id\": \"fada9c248ccea6ea3f7525787bd888af\", \"span_id\": \"...\", \"message\": \"demo error for Loki\"}"}
```

因此查询时要先解外层，再解内层：

```logql
{namespace="demo", pod=~"log-demo-.*"}
  | json
  | line_format "{{.log}}"
  | json
```

### 4.2 日志 → Tempo

Loki 数据源配置了 derived field：

```yaml
derivedFields:
  - name: TraceID
    matcherType: regex
    matcherRegex: 'trace_id[^a-f0-9]*([a-f0-9]{32})'
    datasourceUid: tempo
    url: '$${__value.raw}'
    urlDisplayLabel: 'View trace'
```

点击日志行里的 `TraceID` / `View trace`，Grafana 用捕获到的 32 位十六进制 ID 打开 Tempo。

实际结果：error 日志成功打开 `log-demo: GET /error`，trace ID 为 `fada9c248ccea6ea3f7525787bd888af`。

### 4.3 Tempo → 日志

Tempo 数据源配置了 `tracesToLogsV2`：

```yaml
tracesToLogsV2:
  datasourceUid: loki
  spanStartTimeShift: '-5m'
  spanEndTimeShift: '5m'
  customQuery: true
  query: '{namespace="demo", pod=~"log-demo-.*"} | json | line_format "{{.log}}" | json | trace_id="$${__trace.traceId}"'
```

在 Tempo span 详情里点击 **Related logs**，Grafana 自动生成：

```logql
{namespace="demo", pod=~"log-demo-.*"} | json | line_format "{{.log}}" | json | trace_id="fada9c248ccea6ea3f7525787bd888af"
```

实际结果：Loki 返回同一条 error 日志，说明 trace → 日志方向也成立。

> Grafana 这个版本的按钮显示为 **Related logs**，不是旧文档里的 “Logs for this span”；底层使用的都是 `tracesToLogsV2`。

## 5. 资源占用

验收时：

```bash
kubectl top pods -n tracing
kubectl top pods -n demo
kubectl top nodes
```

结果：

| Pod / 节点 | CPU | 内存 |
|---|---:|---:|
| `tempo-0` | 4m | 38Mi |
| `otel-collector` | 1m | 36Mi |
| `log-demo` | 1m | 28Mi |
| `k8s-server` | 98m（2%） | 3636Mi（61%） |
| `k8s-worker-1` | 29m（0%） | 1057Mi（36%） |
| `k8s-worker-2` | 35m（1%） | 1512Mi（51%） |

结论：

- Tempo 和 Collector 的实际内存远低于各自 limit。
- `k8s-server` 仍有约 39% 内存余量，没有接近 80% 红线。
- 当前 16 GB 宿主机可以继续做阶段 5，但不要同时再堆一个重型后端。

## 6. 偏差与已知噪声

### 偏差

1. **Tempo chart 下载失败**：`k8s-server` 从 GitHub Releases 下载 `tempo-3.2.1.tgz` 时连接被重置。改为在 Windows 下载同一官方 chart，校验 SHA256 和 `Chart.yaml` 后 `scp` 到 server，用本地 chart 安装。
2. **Collector exporter 别名**：`0.163.2` 提示 `otlp` 别名弃用，已改为 `otlp_grpc`；receiver 仍叫 `otlp`。
3. **readiness probe 污染**：最初 readiness probe 请求 `/`，每 5 秒生成一条 info 日志和一个 trace。已增加 `/healthz`，在创建 span 之前直接返回 200，readiness 改为请求 `/healthz`。
4. **Grafana 按钮名称**：当前版本显示 **Related logs**，不是 “Logs for this span”。
5. **旧探针 trace 仍保留**：修复前旧 Pod 产生的探针 trace 已进入 Tempo，不会自动删除；Tempo 保留期到后自然清理。验收时按 trace ID 精确查询，避免把旧探针 trace 当成手动请求。

### 已知噪声

Tempo 3 单机空闲时日志会出现：

```text
level=error ... msg="error calling scheduler" err="rpc error: code = NotFound desc = no jobs found"
```

这是 Tempo 3 没有 compaction/backend 任务时的已知空闲噪声。当前 `tempo-0` 为 `1/1 Running`，`/ready` 为 `ready`，不影响 trace 写入和查询。不要为了消除日志而关闭 backend scheduler/worker；等有真实数据后再观察。

## 7. 未完成项

本阶段没有做：

- 对象存储（S3/MinIO）和 Tempo 分布式部署。
- Tempo metrics-generator、span metrics、service graph。
- 采样、tail sampling、鉴权和 TLS。
- Tempo/Collector 的 NodePort 或 Ingress。
- Grafana 仪表盘和告警规则。
- 旧探针 trace 的主动清理。

这些不是阶段 4 的验收阻塞项，留给后续生产化或阶段 5。

## 8. 复现命令

```bash
# 组件状态
helm list -n tracing
kubectl get sts,pod,pvc,svc -n tracing -o wide
kubectl get pods -n demo -o wide
kubectl get configmap -n monitoring | grep -E 'loki-datasource|tempo-datasource'

# Tempo 就绪
kubectl exec -n demo deploy/log-demo -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://tempo.tracing.svc.cluster.local:3200/ready").read().decode())'

# 生成 info 和 error
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

# 查 Tempo trace
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import json
import urllib.request

trace_id = "fada9c248ccea6ea3f7525787bd888af"
url = f"http://tempo.tracing.svc.cluster.local:3200/api/traces/{trace_id}"
data = json.load(urllib.request.urlopen(url))
for batch in data["batches"]:
    for scope in batch["scopeSpans"]:
        for span in scope["spans"]:
            print(span["name"], span.get("status", {}))
PY
```

## 9. 快照后验证

已完成：

1. 三台 VM 干净关机。
2. 在 VMware 中分别创建 `phase-4-tracing-ready` 快照。
3. 开机后确认三节点 `Ready`，Tempo、Collector、demo、Loki、Fluent Bit、Grafana、Prometheus 正常。
4. 再做一次 Loki → Tempo 的 `TraceID` 跳转检查。

用户确认：三台快照均已创建，开机后相关 Pod 全部 `Running`，Grafana 跳转仍正常。

## 10. 结论

阶段 4 的链路追踪已经打通：

```text
demo OTel SDK -> OTel Collector -> Tempo -> Grafana
                         |
                         +--> Loki trace_id 关联
```

可以确认：

- demo 能生成真实 trace 和 span。
- Collector 能把 OTLP 数据转发到 Tempo。
- Tempo 能查询并展示 span 树。
- Loki 日志和 Tempo trace 可以双向跳转。
- readiness probe 不再污染日志和 trace。
- 资源占用适合当前 16 GB 实验环境。

下一步：创建 `phase-4-tracing-ready` 快照，然后进入阶段 5（告警与 SLO）。
