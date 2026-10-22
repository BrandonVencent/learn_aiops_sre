# 阶段 2 指标链路验收记录

> 状态：Prometheus、Grafana、node-exporter、kube-state-metrics 和容器重启计数实验已通过；待三台 VM 快照。

## 环境

| 项 | 值 |
|---|---|
| 宿主机 | Windows，16 GB 内存，14 核 20 线程 |
| VMware 网络 | `VMnet8`，`172.25.254.0/24`，网关 `172.25.254.2` |
| `k8s-server` | `172.25.254.10/24`，6 GB 内存 |
| `k8s-worker-1` | `172.25.254.11/24`，3 GB 内存 |
| `k8s-worker-2` | `172.25.254.12/24`，3 GB 内存 |
| 系统 | Ubuntu Server 22.04.5 LTS |
| 内核 | `6.8.0-138-generic` |
| 集群 | k3s `v1.36.5+k3s1` |
| 容器运行时 | `containerd://2.3.4-k3s1.36` |
| Helm | `v3.22.1` |
| Chart | `kube-prometheus-stack` `92.11.0` |
| 命名空间 | `monitoring` |
| values | [`infra/monitoring/values-kube-prometheus-stack.yaml`](../../infra/monitoring/values-kube-prometheus-stack.yaml) |

## 验收清单

- [x] Helm release `kube-prometheus-stack` 部署成功，`REVISION 2`、`STATUS deployed`
- [x] `monitoring` 中所有 Pod `Running`
- [x] Prometheus、Alertmanager、Grafana 的 PVC 全部 `Bound`
- [x] Prometheus `/-/ready` 返回 `Prometheus Server is Ready.`
- [x] 21 个 target 全部 `up=1`，`up=0` 为空
- [x] PromQL 能查到 3 个节点、2 个 demo Pod、3 个节点 CPU
- [x] Grafana 能显示 3 个节点和 2 个 demo Pod
- [x] 容器重启计数实验通过：同一个 Pod 重启计数加 1；删除 Pod 后新 Pod 从 0 开始
- [x] Grafana OOMKilled 已修复，新 Pod 持续 `RESTARTS 0`
- [ ] 三台 VM 快照 `phase-1-k3s-ready`
- [ ] 三台 VM 快照 `phase-2-metrics-ready`

## 1. Helm release

```text
NAME                  NAMESPACE   REVISION   STATUS     CHART
kube-prometheus-stack monitoring  2          deployed   kube-prometheus-stack-92.11.0
```

关键配置：

| 项 | 值 |
|---|---|
| Prometheus 保留 | 7 天，最多 6 GB |
| 抓取间隔 | 15 秒 |
| Grafana NodePort | `30030` |
| Prometheus NodePort | `30090` |
| Alertmanager NodePort | `30093` |
| Prometheus PVC | `10Gi`，`local-path` |
| Alertmanager PVC | `1Gi`，`local-path` |
| Grafana PVC | `1Gi`，`local-path` |

## 2. 监控组件

验收时 `kubectl get pods -n monitoring`：

| 组件 | Pod | READY | 状态 | 节点 |
|---|---|---|---:|---|
| Prometheus | `prometheus-kube-prometheus-stack-prometheus-0` | `2/2` | Running | `k8s-server` |
| Alertmanager | `alertmanager-kube-prometheus-stack-alertmanager-0` | `2/2` | Running | `k8s-worker-1` |
| Grafana | `kube-prometheus-stack-grafana-896986bc4-8cc44` | `3/3` | Running，`RESTARTS 0` | `k8s-server` |
| kube-state-metrics | `kube-prometheus-stack-kube-state-metrics-687686d88b-k4f2f` | `1/1` | Running | `k8s-worker-1` |
| Prometheus Operator | `kube-prometheus-stack-operator-786599478f-4nx86` | `1/1` | Running | `k8s-worker-2` |
| node-exporter | `kube-prometheus-stack-prometheus-node-exporter-hrgg8` | `1/1` | Running | `k8s-server` |
| node-exporter | `kube-prometheus-stack-prometheus-node-exporter-spxdr` | `1/1` | Running | `k8s-worker-1` |
| node-exporter | `kube-prometheus-stack-prometheus-node-exporter-zf6cq` | `1/1` | Running | `k8s-worker-2` |

### Service

```text
kube-prometheus-stack-grafana                    NodePort   80:30030/TCP
kube-prometheus-stack-prometheus                 NodePort   9090:30090/TCP,8080:32746/TCP
kube-prometheus-stack-alertmanager               NodePort   9093:30093/TCP,8080:32226/TCP
kube-prometheus-stack-kube-state-metrics         ClusterIP  8080/TCP
kube-prometheus-stack-operator                   ClusterIP  443/TCP
kube-prometheus-stack-prometheus-node-exporter   ClusterIP  9100/TCP
prometheus-operated                              ClusterIP  None，9090/TCP
alertmanager-operated                            ClusterIP  None，9093/TCP
```

说明：

- Grafana 主入口是 `http://172.25.254.10:30030`。
- Prometheus 主入口是 `http://172.25.254.10:30090`。
- Alertmanager 主入口是 `http://172.25.254.10:30093`。
- Prometheus/Alertmanager 的额外 `8080` 端口是 chart 默认暴露的端口，不影响本阶段验收。

### PVC

```text
prometheus-...-db-...         Bound   local-path   10Gi
alertmanager-...-db-...       Bound   local-path   1Gi
kube-prometheus-stack-grafana Bound   local-path   1Gi
```

`local-path` 是 k3s 自带的默认 StorageClass，`VOLUMEBINDINGMODE` 是 `WaitForFirstConsumer`。PVC 在 Pod 调度后才会绑定，这是正常行为。

## 3. Prometheus target

查询：

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=count by (job) (up == 1)' \
  | python3 -m json.tool
```

结果：

| job | up=1 的 target 数 |
|---|---:|
| `kube-prometheus-stack-operator` | 1 |
| `kubelet` | 9 |
| `kube-prometheus-stack-prometheus` | 2 |
| `kube-state-metrics` | 1 |
| `kube-prometheus-stack-alertmanager` | 2 |
| `node-exporter` | 3 |
| `coredns` | 1 |
| `apiserver` | 1 |
| `kube-prometheus-stack-grafana` | 1 |
| **合计** | **21** |

再确认没有 down target：

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=up == 0' \
  | python3 -m json.tool
```

结果：

```json
{
    "status": "success",
    "data": {
        "resultType": "vector",
        "result": []
    }
}
```

再确认总数：

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=count(up)' \
  | python3 -m json.tool
```

结果：

```text
"21"
```

### 为什么 kubelet 是 9

当前 chart 给 kubelet 配了 3 个抓取端点，通常是：

- `/metrics`
- `/metrics/cadvisor`
- `/metrics/probes`

3 个节点 × 3 个端点 = 9 个 target。不是 9 个节点。

`kube-prometheus-stack-prometheus=2` 和 `kube-prometheus-stack-alertmanager=2` 也是同一个组件的多个 metrics 端点，不是两个实例。

### 为什么没有 etcd/controller-manager/scheduler/kube-proxy

k3s 把这些控制面组件编在一个进程里，没有像 kubeadm 那样独立暴露 metrics 端点。values 中关闭了对应的 ServiceMonitor，避免出现永久 down target：

```yaml
kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
```

## 4. PromQL 验收

### demo Pod 数

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=count(kube_pod_info{namespace="demo"})' \
  | python3 -m json.tool
```

结果：

```text
"2"
```

### 节点数

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=count(kube_node_info)' \
  | python3 -m json.tool
```

结果：

```text
"3"
```

### 节点 CPU 使用率

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)' \
  | python3 -m json.tool
```

结果：

| instance | CPU 使用率 |
|---|---:|
| `172.25.254.10:9100` | 5.86% |
| `172.25.254.11:9100` | 2.14% |
| `172.25.254.12:9100` | 2.10% |

server 略高，因为控制面、Prometheus、Grafana 都在 server 上；两个 worker 只跑业务和部分监控组件。

### demo 容器重启次数（实验前）

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=kube_pod_container_status_restarts_total{namespace="demo"}' \
  | python3 -m json.tool
```

结果：

```text
web-554647c847-42l4t  -> 0
web-554647c847-n44bz  -> 0
```

这里 `instance="10.42.1.6:8080"`、`job="kube-state-metrics"` 表示指标来自 KSM，不是 demo Pod 自己的地址。真正描述 demo Pod 的是 `namespace`、`pod`、`container` 标签。

## 5. Grafana Dashboard

### Kubernetes / Compute Resources / Cluster

观察到：

| 指标 | 值 |
|---|---:|
| CPU Utilisation | 1.33% |
| CPU Requests | 6.80% |
| CPU Limits | 23.0% |
| Memory Utilisation | 38.6% |
| Memory Requests | 8.94% |
| Memory Limits | 22.0% |

CPU Quota 表：

| Namespace | Pods | CPU Usage | CPU Requests | CPU Limits |
|---|---:|---:|---:|---:|
| `monitoring` | 8 | 0.0397 | 0.380 | 1.90 |
| `kube-system` | 7 | 0.00535 | 0.200 | — |
| `demo` | 2 | 0.000103 | 0.100 | 0.400 |

说明：`CPU Usage` 的单位是 cores，不是百分比；`CPU Utilisation` 才是百分比。

### Kubernetes / Compute Resources / Namespace (Pods)

namespace 选择 `demo`：

| 指标 | 值 |
|---|---:|
| CPU Utilisation (from requests) | 0.102% |
| CPU Utilisation (from limits) | 0.0255% |
| Memory Utilisation (from requests) | 5.80% |
| Memory Utilisation (from limits) | 2.90% |
| Pod 数 | 2 |

表格里能看到两个 web Pod：

```text
web-554647c847-42l4t
web-554647c847-n44bz
```

### Node Exporter / Nodes

instance 下拉框里有 3 个节点：

```text
172.25.254.10:9100
172.25.254.11:9100
172.25.254.12:9100
```

server 的 Memory Usage 面板约 `46.8%`（截图时点），CPU、Load Average、Memory、磁盘和网络都有数据。

## 6. Grafana OOMKilled 修复

### 现象

Grafana 反复重启，`RESTARTS 3`，事件里反复出现：

```text
Readiness probe failed: Get "http://10.42.0.85:3000/api/health": connect: connection refused
Back-off restarting failed container grafana
```

### 根因

`kubectl describe pod`：

```text
Last State: Terminated
  Reason: OOMKilled
  Exit Code: 137
```

不是 readiness probe 导致重启。Readiness 失败只会把 Pod 从 Service endpoints 摘掉，不会重启容器；真正原因是内存超限。

Grafana 13.2.4 启动时加载 56 个插件，原来的 memory limit `256Mi` 不够。

### 修复

修改 [`infra/monitoring/values-kube-prometheus-stack.yaml`](../../infra/monitoring/values-kube-prometheus-stack.yaml)：

```yaml
grafana:
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
    limits:
      cpu: 200m
      memory: 512Mi
```

执行：

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 92.11.0 \
  -f /root/monitoring/values-kube-prometheus-stack.yaml
```

### 修复后

| 项 | 修复前 | 修复后 |
|---|---:|---:|
| Grafana memory request | 128Mi | 256Mi |
| Grafana memory limit | 256Mi | 512Mi |
| 实际内存 | 约 380Mi（已超过旧 limit） | 约 380Mi |
| 重启次数 | 3 | 0（观察 28 分钟） |
| Pod | `...-7c6bcdb755-87llc` | `...-896986bc4-8cc44` |

修复后仍会在启动阶段看到一次 readiness 失败：

```text
Readiness probe failed: ... connection refused
```

这是正常的：Readiness 的 `delay=0s`，而 Grafana 需要十几秒启动。只要之后 `RESTARTS` 不增长，就不需要处理。

Liveness 配置是 `delay=60s`、`timeout=30s`、`failure=10`，启动期间不会触发；之前的重启不是 liveness 导致的。

详细问答见 [`03-qa/2026-10-21.md` 第 21 节](../03-qa/2026-10-21.md#21-grafana-反复重启oomkilled)。

## 7. 容器重启计数实验

### 实验 A：容器重启，Pod 不变

对一个 web Pod 执行：

```bash
kubectl exec -n demo web-554647c847-42l4t -- kill 1
```

本次命令没有输出。`kill 1` 杀掉 nginx 主进程，kubelet 按 `restartPolicy: Always` 重启容器。

结果：

```text
web-554647c847-42l4t   1/1   Running   1 (26s ago)
```

PromQL：

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=kube_pod_container_status_restarts_total{namespace="demo",pod="web-554647c847-42l4t"}' \
  | python3 -m json.tool
```

结果：

```text
"1"
```

### 实验 B：删除 Pod，新 Pod 从 0 开始

删除另一个 Pod：

```bash
kubectl delete pod -n demo web-554647c847-n44bz
```

Deployment 创建新 Pod：

```text
web-554647c847-42l4t   1/1   Running   1 (63s ago)   10.42.1.4    k8s-worker-1
web-554647c847-8qq4w   0/1   Running   0             6s          10.42.2.11   k8s-worker-2
```

新 Pod 创建 6 秒时 `READY 0/1`，说明容器已经 Running，但 readiness 还没通过；等几秒后会变成 `1/1`。

PromQL：

```bash
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=kube_pod_container_status_restarts_total{namespace="demo"}' \
  | python3 -m json.tool
```

结果：

```text
web-554647c847-42l4t  -> 1
web-554647c847-8qq4w  -> 0
```

注意：被删除 Pod 的 series 可能在 Prometheus 里短暂保留，这是正常的 staleness/lookback 行为；以新 Pod 的 0 为准。

### 结论

| 操作 | Pod | 结果 |
|---|---|---|
| `kill 1` | `web-554647c847-42l4t` | 同一个 Pod，`RESTARTS` 0 → 1 |
| `kubectl delete pod` | `web-554647c847-n44bz` → `web-554647c847-8qq4w` | 新 Pod，`RESTARTS` 从 0 开始 |

这说明：

- 容器重启计数属于 **Pod 内的容器**。
- 删除 Pod 是 **重建 Pod**，新 Pod 的计数器归零。

## 8. 资源余量

从验收时的 Dashboard 和 PromQL 观察：

| 项 | 值 |
|---|---:|
| 集群 CPU 使用率 | 1.33% |
| 集群内存使用率 | 38.6% |
| server 节点 CPU | 5.86% |
| worker-1 节点 CPU | 2.14% |
| worker-2 节点 CPU | 2.10% |
| Grafana 实际内存 | 约 380Mi / 512Mi |
| demo CPU requests / limits | 0.100 / 0.400 cores |
| monitoring CPU requests / limits | 0.380 / 1.90 cores |

当前资源余量足够继续阶段 3（Loki + Fluent Bit）。后续加日志组件时，仍要先看 server 和 worker 的可用内存，不要把所有组件都堆到 server。

## 9. 与计划的偏差

1. **Grafana 内存**：计划是 request `128Mi` / limit `256Mi`，实际因 OOMKilled 调整为 `256Mi` / `512Mi`。
2. **Grafana 版本**：实际 chart 使用 Grafana `13.2.4-distroless`，启动时加载 56 个插件，内存占用比预期高。
3. **kubelet target 数**：是 9 而不是 3，原因是每个节点有 3 个 kubelet 抓取端点，不是异常。
4. **Prometheus/Alertmanager target 数**：各 2 个，属于同一组件的多个 metrics 端点，不是多副本。
5. **额外端口**：Prometheus/Alertmanager Service 还有 `8080` 映射，chart 默认行为，不影响主入口。
6. **新 Pod 启动**：删除 Pod 后新 Pod 在 6 秒时 `READY 0/1`，是 readiness 尚未通过；容器已 Running，重启计数为 0。

## 10. 待完成与快照

阶段 2 的指标验收已完成，收尾还需要：

```text
[ ] 确认三台 VM 有 phase-1-k3s-ready 快照
[ ] 三台 VM 打 phase-2-metrics-ready 快照
```

快照顺序建议：

1. 先确认阶段 1 快照存在；如果没有，先补 `phase-1-k3s-ready`。
2. 再给三台 VM 打 `phase-2-metrics-ready`。
3. 快照完成后再进入阶段 3，避免日志组件把当前可回滚状态覆盖掉。

## 11. 复现命令汇总

```bash
# Helm release
helm list -n monitoring

# 监控 Pod 和 PVC
kubectl get pods -n monitoring -o wide
kubectl get pvc -n monitoring

# Prometheus Ready
curl -s http://172.25.254.10:30090/-/ready

# 所有 target 总数和 down target
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=count(up)' | python3 -m json.tool

curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=up == 0' | python3 -m json.tool

# demo Pod 数、节点数
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=count(kube_pod_info{namespace="demo"})' | python3 -m json.tool

curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=count(kube_node_info)' | python3 -m json.tool

# 容器重启次数
curl -sG 'http://172.25.254.10:30090/api/v1/query' \
  --data-urlencode 'query=kube_pod_container_status_restarts_total{namespace="demo"}' \
  | python3 -m json.tool
```

## 12. 结论

阶段 2 的指标链路已经打通：

```text
node-exporter / kubelet / KSM / apiserver / coredns
        ↓
Prometheus 抓取、存储
        ↓
Grafana 查询、展示
```

可以确认：

- 三台节点和 demo Pod 的指标都能被采集和查询。
- 21 个 target 全部健康。
- Grafana 能展示集群、Namespace、Node 三个层面的数据。
- 容器重启计数可以区分「容器重启」和「Pod 重建」。
- Grafana 的内存问题已经定位并修复。

阶段 2 的代码和文档完成后，下一步进入阶段 3：Loki + Fluent Bit 日志链路。
