# 阶段 3 日志链路验收记录

> 状态：验收通过；旧手工 Loki 数据源已删除；三台 VM 已创建 `phase-3-logging-ready` 快照。

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
| 日志命名空间 | `logging` |
| Loki chart / 应用 | `loki-19.0.3` / `3.7.9` |
| Loki 镜像 | `docker.io/grafana/loki:3.7.9` |
| Fluent Bit chart / 应用 | `fluent-bit-0.58.3` / `5.1.3` |
| Fluent Bit 镜像 | `fluent/fluent-bit:5.1.3` |
| Grafana | `kube-prometheus-stack-92.11.0`，NodePort `30030` |
| values | [`infra/logging/values-loki.yaml`](../../infra/logging/values-loki.yaml)、[`infra/logging/values-fluent-bit.yaml`](../../infra/logging/values-fluent-bit.yaml) |

## 验收清单

- [x] Loki Helm release `loki` 部署成功，`REVISION 1`、`STATUS deployed`
- [x] `loki-0` 为 `1/1 Running`，运行在 `k8s-worker-2`
- [x] PVC `storage-loki-0` 为 `Bound`，`5Gi`、`local-path`
- [x] Loki `/ready`、`/metrics`、`/buildinfo` 验证通过
- [x] Fluent Bit Helm release `fluent-bit` 升级成功，`REVISION 2`、`STATUS deployed`
- [x] 三个 Fluent Bit Pod 全部 `1/1 Running`，`RESTARTS 0`
- [x] Fluent Bit 能采集 `demo` 和 `monitoring` 两个命名空间
- [x] Loki labels 包含 `container`、`job`、`namespace`、`pod`、`service_name`
- [x] demo 的 error JSON 能进入 Loki
- [x] 嵌套 LogQL 能按 `level="error"` 和 `level="info"` 过滤
- [x] Python traceback 合并成一条多行日志
- [x] Grafana provisioning 数据源 `Loki` 健康检查通过
- [x] 删除 Grafana 里旧的手工 `loki` 数据源，只保留 `Loki`
- [x] 三台 VM 创建 `phase-3-logging-ready` 快照
- [x] 快照恢复后三节点 `Ready`，Loki 和 Fluent Bit Pod 全部 `Running`

## 1. Helm release

```text
NAME         NAMESPACE   REVISION   STATUS     CHART                  APP VERSION
fluent-bit   logging     2          deployed   fluent-bit-0.58.3      5.1.3
loki         logging     1          deployed   loki-19.0.3            3.7.9
```

## 2. 组件与存储

### Loki

| 项 | 值 |
|---|---|
| 部署模式 | `Monolithic` |
| 副本 | 1 |
| 节点 | `k8s-worker-2` |
| PVC | `storage-loki-0`，`5Gi`，`local-path` |
| Service | `loki.logging.svc.cluster.local:3100` |
| 保留期 | 7 天（`168h`） |
| 认证 | `auth_enabled: false` |

### Fluent Bit

| 项 | 值 |
|---|---|
| 类型 | DaemonSet |
| Pod 数 | 3 |
| 采集路径 | `/var/log/containers/*.log` |
| 输出 | `http://loki.logging.svc.cluster.local:3100` |
| 标签 | `job`、`namespace`、`pod`、`container` |
| Service | `fluent-bit`，ClusterIP `10.43.59.66:2020` |

验收时 Pod：

| Pod | READY | 状态 | 节点 | IP |
|---|---|---|---|---|
| `fluent-bit-8wv7c` | `1/1` | Running，RESTARTS 0 | `k8s-server` | `10.42.0.98` |
| `fluent-bit-lshbz` | `1/1` | Running，RESTARTS 0 | `k8s-worker-1` | `10.42.1.14` |
| `fluent-bit-zc7th` | `1/1` | Running，RESTARTS 0 | `k8s-worker-2` | `10.42.2.19` |

### Grafana 数据源

provisioning 文件来自：

[`infra/logging/grafana-loki-datasource.yaml`](../../infra/logging/grafana-loki-datasource.yaml)

| 项 | 值 |
|---|---|
| 名称 | `Loki` |
| UID | `loki` |
| 类型 | `loki` |
| URL | `http://loki.logging.svc.cluster.local:3100` |
| 健康检查 | `status=ok` |
| 可编辑 | `false` |

## 3. 日志数据流

```text
容器 stdout/stderr
      ↓
/var/log/containers/*.log
      ↓
Fluent Bit tail（CRI 解析）
      ↓
multiline filter（Python 堆栈合并）
      ↓
kubernetes filter（补 namespace/pod/container）
      ↓
Loki output（Line_Format json）
      ↓
Loki 存储
      ↓
Grafana / LogQL 查询
```

## 4. 查询验收

### 4.1 Loki labels

```bash
curl -s http://127.0.0.1:3100/loki/api/v1/labels \
  | python3 -m json.tool
```

结果包含：

```text
container, job, namespace, pod, service_name
```

### 4.2 demo error 日志

先触发 `/error`：

```bash
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import urllib.request

try:
    urllib.request.urlopen("http://127.0.0.1:8080/error")
except Exception as exc:
    print("request result:", type(exc).__name__, exc)
PY
```

预期：

```text
request result: HTTPError HTTP Error 500: Internal Server Error
```

查询 error：

```logql
{namespace="demo", pod=~"log-demo-.*"}
  | json
  | line_format "{{.log}}"
  | json
  | level="error"
```

结果：返回 3 条 error JSON，其中一条为：

```json
{
  "ts": "2026-10-22T13:20:02.670389+00:00",
  "level": "error",
  "service": "log-demo",
  "trace_id": "demo-trace-001",
  "message": "demo error for Loki"
}
```

### 4.3 demo info 日志

```logql
{namespace="demo", pod=~"log-demo-.*"}
  | json
  | line_format "{{.log}}"
  | json
  | level="info"
```

结果：返回 readinessProbe 产生的 `hello from log-demo` 日志，`level` 为 `info`。

### 4.4 多行 traceback

```logql
{namespace="demo"} |= "Traceback"
```

结果只有 1 个 values 条目，`line` 包含：

```text
Traceback (most recent call last):
  File "/app/app.py", line 39, in do_GET
    raise RuntimeError("demo error for Loki")
RuntimeError: demo error for Loki
```

这证明 traceback 已经不是四条独立记录。

### 4.5 其他命名空间

```logql
{namespace="monitoring"}
```

结果非空，能看到 Grafana sidecar 等 Pod 的日志，说明 DaemonSet 不是只采集 `demo`。

## 5. 多行 traceback 修复

### 现象

最初 Tail 配置是：

```ini
multiline.parser cri, python
```

查询 `|= "Traceback"` 时只有第一行：

```json
{"_p":"F","log":"Traceback (most recent call last):"}
```

后续 `File ...`、`raise ...`、`RuntimeError ...` 都是独立记录。

### 根因

- `cri` 负责 CRI 运行时拆行，不负责应用自己的 Python traceback。
- Tail 的 `cri, python` 组合没有合并应用堆栈。
- 应用堆栈需要在 CRI 解析之后，用单独的 `multiline` filter 处理。

### 最终配置

Tail：

```ini
multiline.parser cri
```

Filters：

```ini
[FILTER]
    Name multiline
    Match kube.*
    multiline.key_content log
    multiline.parser python

[FILTER]
    Name kubernetes
    Match kube.*
    Merge_Log Off
    Keep_Log On
    K8S-Logging.Parser On
    K8S-Logging.Exclude On
```

说明：

- `multiline` 必须是第一个 filter；它会把合并后的记录重新送回 pipeline 头部。
- 没有启用 `Buffer On`：官方文档说明 Tail 是例外；先保持最小配置。
- 如果以后确认 traceback 跨 chunk 到达，再单独加 `Buffer On`。

详细问答见 [`03-qa/2026-10-22.md` 第 19 节](../03-qa/2026-10-22.md#qa-19)。

## 6. level 过滤的当前写法

Loki 里保存的原始行仍然是：

```json
{"_p":"F","log":"{\"ts\":\"...\",\"level\":\"error\",...}"}
```

原因：

- Fluent Bit output 使用 `Line_Format json`。
- `Merge_Log Off`，应用 JSON 没有被展开到顶层。
- `_p` 没有加入 `Remove_Keys`。

因此简单写法：

```logql
{namespace="demo"} | json | level="error"
```

只能解析出外层 `_p` 和 `log`，取不到 `level`。

当前验收使用嵌套写法：

```logql
{namespace="demo", pod=~"log-demo-.*"}
  | json
  | line_format "{{.log}}"
  | json
  | level="error"
```

这不是把 `level` 做成 Loki label，而是在查询时解析。

后续如果要支持简单写法，可以单独做一次变更：

- `Merge_Log On`
- 把 `_p` 加入 `Remove_Keys`

本次没有做，避免和 multiline 修复混在一起。详细问答见 [`03-qa/2026-10-22.md` 第 18 节](../03-qa/2026-10-22.md#qa-18)。

## 7. 资源占用

验收时：

```bash
kubectl top pods -n logging
kubectl top nodes
```

结果：

| Pod / 节点 | CPU | 内存 |
|---|---:|---:|
| `fluent-bit-8wv7c` | 3m | 5Mi |
| `fluent-bit-lshbz` | 4m | 5Mi |
| `fluent-bit-zc7th` | 4m | 5Mi |
| `loki-0` | 9m | 87Mi |
| `k8s-server` | 118m（2%） | 3552Mi（60%） |
| `k8s-worker-1` | 21m（0%） | 1336Mi（45%） |
| `k8s-worker-2` | 29m（0%） | 1366Mi（46%） |

结论：

- Loki 和 Fluent Bit 的资源占用远低于 limit。
- worker-2 仍有充足内存。
- 当前日志量适合 7 天保留期。

## 8. 快照后验证

Grafana 数据源清理完成：旧手工 `loki`（UID `dg1zqi7tex9fke`）已删除，只保留 provisioning 的 `Loki`（UID `loki`）。

三台 VM 干净关机后，在 VMware 中分别创建名为 `phase-3-logging-ready` 的快照。开机后确认：

```text
NAME           STATUS   ROLES           AGE   VERSION
k8s-server     Ready    control-plane   28h   v1.36.5+k3s1
k8s-worker-1   Ready    <none>          28h   v1.36.5+k3s1
k8s-worker-2   Ready    <none>          28h   v1.36.5+k3s1
```

```text
NAME               READY   STATUS    RESTARTS   AGE
fluent-bit-8wv7c   1/1     Running   0          13m
fluent-bit-lshbz   1/1     Running   0          13m
fluent-bit-zc7th   1/1     Running   0          13m
loki-0             1/1     Running   0          171m
```

说明：

- 快照恢复后三个节点重新加入集群。
- Loki 和三个 Fluent Bit Pod 自动恢复，没有手工重建。
- 后续如果阶段 4 配置失败，可以回滚到 `phase-2-metrics-ready` 或本次 `phase-3-logging-ready`。

## 9. 已知偏差与未完成项

### 偏差

1. Loki 使用 `Monolithic`，不是旧命名的 `SingleBinary`。
2. 原始日志仍带 `_p` 外层包装；`level` 过滤使用嵌套解析。
3. Tail 多行配置从 `cri, python` 改为 `cri` + 独立 `multiline` filter。
4. `detected_level` 对部分 info 日志显示 `unknown`，因为 Loki 不会自动解析 `log` 里的嵌套 JSON；验收以查询时解析出的 `level` 为准。
5. 本阶段没有部署 Tempo/OTel，日志中的 `trace_id` 还没有和 trace 关联。

### 已完成收尾

- [x] 删除 Grafana 旧的手工 `loki` 数据源（UID `dg1zqi7tex9fke`），只保留 provisioning 的 `Loki`（UID `loki`）。
- [x] 三台 VM 创建 `phase-3-logging-ready` 快照。

### 历史遗留与仓库事项

- [x] 阶段 1 的 `phase-1-k3s-ready` 历史快照已确认（2026-10-22）。
- [x] 本地提交已推送：远端更新到 `1bf6197`（`10f3b14..1bf6197`）。

## 10. 复现命令汇总

```bash
# Helm release
helm list -n logging

# 日志组件
kubectl get pods -n logging -o wide
kubectl get pvc -n logging
kubectl get svc -n logging

# Fluent Bit 日志
kubectl logs -n logging \
  -l app.kubernetes.io/name=fluent-bit \
  --tail=100 \
  --prefix=true

# Loki 数据源健康
kubectl logs -n monitoring \
  deploy/kube-prometheus-stack-grafana \
  -c grafana \
  --since=10m \
  | grep -i 'loki.*status'

# demo 多行 traceback
kubectl exec -i -n demo deploy/log-demo -- python - <<'PY'
import urllib.request

try:
    urllib.request.urlopen("http://127.0.0.1:8080/error")
except Exception as exc:
    print("request result:", type(exc).__name__, exc)
PY

# Loki 查询
START=$(date -d '10 minutes ago' +%s)000000000
END=$(date +%s)000000000

curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="demo"} |= "Traceback"' \
  --data-urlencode "start=$START" \
  --data-urlencode "end=$END" \
  --data-urlencode 'limit=20' \
  | python3 -m json.tool
```

## 11. 结论

阶段 3 的日志链路已经打通：

```text
Fluent Bit DaemonSet
        ↓
Loki 单机文件系统存储
        ↓
Grafana / LogQL
```

可以确认：

- 三个节点上的容器日志都能被采集。
- namespace、pod、container、job 标签可用于定位。
- JSON 日志可以按 `level` 过滤。
- Python traceback 可以合并成一条多行日志。
- Loki 数据源在 Grafana 中健康。
- 旧手工数据源已删除。
- 资源占用适合当前 16 GB 宿主机实验环境。
- 三台 VM 已有 `phase-3-logging-ready` 快照，快照恢复后组件正常。

后续：

1. 阶段 1 的历史快照 `phase-1-k3s-ready` 已确认，无需补打。
2. 阶段 4 已完成：Tempo + OTel Collector + demo OTel SDK，日志 `trace_id` 已能和 trace 双向关联。验收记录见 [阶段 4 链路追踪验收记录](04-phase-4-acceptance.md)。
