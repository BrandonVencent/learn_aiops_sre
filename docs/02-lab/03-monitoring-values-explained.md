# kube-prometheus-stack values 文件逐段解释

对应文件：

```text
infra/monitoring/values-kube-prometheus-stack.yaml
```

安装参数：

```text
chart: prometheus-community/kube-prometheus-stack
version: 92.11.0
namespace: monitoring
```

这份 values 主要做四件事：

1. 把监控组件固定到 `monitoring` 命名空间。
2. 给每个长期运行的组件设置 `requests` / `limits`。
3. 用 `local-path` PVC 保存 Prometheus、Alertmanager、Grafana 的数据。
4. 用固定 NodePort 暴露 Grafana、Prometheus、Alertmanager。

同时关闭 k3s 不存在的控制面 metrics target，避免 Prometheus 出现永久 down 的 target。

## 1. 顶层结构

| 顶层 key | 控制什么 |
|---|---|
| `prometheus` | Prometheus 实例、Service、PVC、资源 |
| `alertmanager` | Alertmanager 实例、Service、PVC、资源 |
| `grafana` | Grafana Deployment、Service、PVC、Dashboard |
| `kubeStateMetrics` | kube-state-metrics，提供 `kube_*` 指标 |
| `prometheus-node-exporter` | node-exporter，提供节点级 `node_*` 指标 |
| `prometheusOperator` | Prometheus Operator，负责监听 CRD 并创建 Prometheus/Alertmanager |
| `kubeEtcd` 等 | 是否为控制面组件创建 ServiceMonitor |

## 2. Prometheus 部分

```yaml
prometheus:
  service:
    type: NodePort
    nodePort: 30090
```

- `type: NodePort`：在每个节点上开放一个端口。
- `nodePort: 30090`：Windows 可以通过 `http://172.25.254.10:30090` 访问 Prometheus UI。
- NodePort 只适合实验环境；生产一般用 Ingress + TLS + 认证。

```yaml
  prometheusSpec:
    replicas: 1
```

- 只跑一个 Prometheus Pod。
- 单副本没有高可用；配合 `local-path` 的 `ReadWriteOnce` PVC 也更简单。
- 如果要多副本，需要每个副本独立存储，通常还要 Thanos 或远程存储。

```yaml
    retention: 7d
    retentionSize: 6GB
```

- `retention`：时间保留期，超过 7 天的数据会被删除。
- `retentionSize`：数据大小上限，超过 6 GB 会触发删除。
- 两个条件谁先满足就按谁删。`retentionSize` 不是精确到字节的硬限制，Prometheus 在 block 级别做清理。

```yaml
    scrapeInterval: 15s
    evaluationInterval: 15s
```

- `scrapeInterval`：默认每 15 秒抓一次指标。
- `evaluationInterval`：每 15 秒计算一次告警/记录规则。
- 15 秒是实验环境里分辨率和资源消耗的折中。抓得越频繁，Prometheus 的 CPU、内存、磁盘压力越大。

```yaml
    walCompression: true
```

- 压缩 WAL（预写日志），减少磁盘占用，代价是一点 CPU。
- 对小集群和本地磁盘比较划算。

```yaml
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
```

- 默认情况下，chart 会让 Prometheus 只选择带 Helm release 标签的 ServiceMonitor/PodMonitor/PrometheusRule。
- 设成 `false` 后，选择器变成“空”，Prometheus 会发现所有命名空间里的这些对象。
- 好处：以后给业务加 ServiceMonitor，不用改 Prometheus CR。
- 代价：多租户集群里权限边界会变松。这个实验是单租户，可以接受；生产要配合 namespace selector 限制范围。

```yaml
    resources:
      requests:
        cpu: 200m
        memory: 300Mi
      limits:
        cpu: "1"
        memory: 1200Mi
```

- `requests` 是调度依据：Kubernetes 保证节点至少有 200m CPU、300Mi 内存才把 Pod 放上去。
- `limits` 是上限：Prometheus 最多用 1 核、1.2 GiB 内存。
- Prometheus 内存和“活跃时间序列数量”强相关。指标越多、保留越久，内存越大。
- 如果 `kubectl describe pod` 看到 `OOMKilled`，先降 `retention` / `retentionSize`，或者减少抓取目标，再考虑提高 limit。

```yaml
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 10Gi
```

- 这段会让 Prometheus Operator 创建一个 PVC，挂到 Prometheus Pod 的 `/prometheus`。
- `local-path` 是 k3s 自带的动态存储：数据实际落在 Pod 所在节点的一个目录里。
- `ReadWriteOnce` 表示同一时间只能被一个节点挂载。单副本 Prometheus 没问题。
- `10Gi` 给 6 GB 保留数据 + WAL + 压缩临时空间留余量。
- `local-path` 的 `volumeBindingMode` 是 `WaitForFirstConsumer`：PVC 一开始可能是 `Pending`，等 Pod 调度到某个节点后才 `Bound`，这是正常的。

## 3. Alertmanager 部分

```yaml
alertmanager:
  service:
    type: NodePort
    nodePort: 30093
```

- 暴露 Alertmanager UI：`http://172.25.254.10:30093`。
- 阶段 2 先让告警能进来、能在 UI 看到；真正的通知渠道和静默策略留到阶段 5。

```yaml
  alertmanagerSpec:
    replicas: 1
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
```

- 单副本，不做 Alertmanager 集群。
- 它主要负责告警分组、抑制、静默和发送，资源占用比 Prometheus 小很多。
- 128Mi 上限对少量告警足够。

```yaml
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
```

- 保存 silences、通知状态等数据。
- 1Gi 对实验环境足够。

## 4. Grafana 部分

```yaml
grafana:
  service:
    type: NodePort
    nodePort: 30030
```

- Grafana UI：`http://172.25.254.10:30030`。
- 默认用户名 `admin`，密码由 chart 随机生成，存在 Secret 里。

```yaml
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
    limits:
      cpu: 200m
      memory: 512Mi
```

- Grafana 13.2.4 在启动时会加载 56 个插件，256Mi limit 下出现过 OOMKilled（Exit Code 137）。
- 所以把 request 提到 256Mi，limit 提到 512Mi。
- 如果后面装更多插件或导入大量 Dashboard，再继续提高 limit。

```yaml
  persistence:
    enabled: true
    storageClassName: local-path
    size: 1Gi
```

- 把 Grafana 的 SQLite 数据库放到 PVC。
- 这样重启 Grafana Pod 后，自己建的 Dashboard、用户、数据源不会丢。
- 如果不启用，数据在 Pod 的 `emptyDir` 里，Pod 重建就没了。

```yaml
  defaultDashboardsEnabled: true
  sidecar:
    dashboards:
      enabled: true
```

- `defaultDashboardsEnabled`：安装 chart 自带的 Kubernetes / Node Exporter 等 Dashboard。
- `sidecar.dashboards.enabled`：启动 Grafana sidecar，监听带 `grafana_dashboard` 标签的 ConfigMap，把 Dashboard 自动加载进来。
- 这两个一起用，Grafana 打开后就能看到基础面板，不需要手工导入。

> 当前没有单独给 Grafana sidecar 写 resources，使用 chart 默认值。它占用很小；如果 server 内存紧张，再在 `grafana.sidecar.dashboards` 下补 `resources`。

## 5. kube-state-metrics

```yaml
kubeStateMetrics:
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

- kube-state-metrics 监听 Kubernetes API，把对象状态转成指标。
- 你后面要查的这些指标都来自它：
  - `kube_pod_info`
  - `kube_pod_container_status_restarts_total`
  - `kube_node_info`
  - `kube_deployment_status_replicas`
- 它不采集节点 CPU/内存，那是 node-exporter 的工作。

## 6. node-exporter

```yaml
prometheus-node-exporter:
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi
```

- node-exporter 是 DaemonSet，每个节点一个 Pod，所以这里会有 3 个实例。
- 它采集节点级指标：
  - `node_cpu_seconds_total`
  - `node_memory_MemAvailable_bytes`
  - `node_filesystem_avail_bytes`
  - `node_network_receive_bytes_total`
- 资源占用很小，64Mi 上限足够。

## 7. Prometheus Operator

```yaml
prometheusOperator:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

- Operator 监听 `Prometheus`、`Alertmanager`、`ServiceMonitor`、`PodMonitor`、`PrometheusRule` 这些 CRD。
- 你写的 values 最终由 Operator 转成 Prometheus/Alertmanager 的 StatefulSet、Service、PVC。
- 它挂了，Prometheus/Alertmanager 的变更就不会生效。

## 8. 关闭 k3s 不存在的控制面 target

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

k3s 和标准 kubeadm 集群不一样：

- k3s 默认使用 SQLite/Kine，不是独立 etcd。
- controller-manager、scheduler、kube-proxy 编在 k3s 进程里，没有独立的 metrics Service。
- 如果保留这些 ServiceMonitor，Prometheus Targets 里会出现永远 `down` 的 target，容易误判。

所以这里直接关闭。保留默认开启的：

- `kube-apiserver`
- `kubelet`
- `coreDns`

这三个在 k3s 上能正常抓。

## 9. 资源预算

按 values 里的 requests 估算：

| 组件 | CPU requests | 内存 requests |
|---|---:|---:|
| Prometheus | 200m | 300Mi |
| Alertmanager | 50m | 64Mi |
| Grafana | 50m | 256Mi |
| kube-state-metrics | 10m | 64Mi |
| node-exporter × 3 | 30m | 96Mi |
| Prometheus Operator | 50m | 64Mi |
| **合计** | **390m** | **844Mi** |

按 limits 估算：

| 组件 | CPU limits | 内存 limits |
|---|---:|---:|
| Prometheus | 1 | 1200Mi |
| Alertmanager | 200m | 128Mi |
| Grafana | 200m | 512Mi |
| kube-state-metrics | 100m | 128Mi |
| node-exporter × 3 | 300m | 192Mi |
| Prometheus Operator | 200m | 128Mi |
| **合计** | **2.0** | **约 2.2Gi** |

server 当前 `available` 约 4.3 GiB，放下这些 limits 还有余量。limits 是上限，不是实际一直占用；实际使用通常低于 limits。

## 10. 这份 values 没有写的东西

- `crds.enabled`：默认 `true`，会安装 Prometheus Operator 的 CRD。
- `kubeStateMetrics.enabled`、`nodeExporter.enabled`、`grafana.enabled`、`alertmanager.enabled`：默认都开启。
- `defaultRules`：默认创建一组告警规则，比如 `Watchdog`。阶段 2 先让规则存在，通知渠道留到阶段 5。
- `adminPassword`：没有写死密码，chart 会生成随机密码，存在 Secret 里。
- `nodeSelector`：没有指定，调度器可能把 Prometheus 等组件放到任意节点。设计上建议放 server；如果安装后发现 Prometheus 在 worker，可以用 `kubectl get pods -n monitoring -o wide` 确认，再通过 `helm upgrade` 加 `nodeSelector`。
- Ingress/TLS/认证：没有配置，当前只通过内网 NodePort 访问。

## 11. 安装后怎么验证 values 生效

```bash
# 看 Helm release
helm list -n monitoring

# 看 Pod 在哪个节点
kubectl get pods -n monitoring -o wide

# 看 PVC 是否 Bound
kubectl get pvc -n monitoring

# 看 Service 和 NodePort
kubectl get svc -n monitoring

# 看 Prometheus CR
kubectl get prometheus -n monitoring
```

渲染阶段可以用：

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 92.11.0 \
  -f /root/monitoring/values-kube-prometheus-stack.yaml \
  > /tmp/kps-rendered.yaml

grep -nE 'nodePort: 300(30|90|93)|storage: (10Gi|1Gi)' /tmp/kps-rendered.yaml
```

## 12. 常见坑

1. **PVC 一直是 Pending**：先看 Pod 是否已经调度；`local-path` 是 `WaitForFirstConsumer`，Pod 没调度前 PVC 不 Bound。
2. **Prometheus OOMKilled**：降低 `retention` / `retentionSize`，或减少抓取目标；再考虑提高 memory limit。
3. **NodePort 访问不了**：确认 Service 是 NodePort、端口没冲突、防火墙放行。
4. **Grafana 没数据**：先看 Prometheus Targets 是否 up，再看 Grafana 数据源 URL 是否正确。
5. **控制面 target down**：确认 `kubeEtcd` / `kubeControllerManager` / `kubeScheduler` / `kubeProxy` 已经关闭。
