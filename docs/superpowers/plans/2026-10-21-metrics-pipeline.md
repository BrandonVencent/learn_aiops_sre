# 阶段 2：指标链路实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在三节点 k3s 上部署 Prometheus、Grafana、node-exporter、kube-state-metrics，能够查询节点和 Pod 指标，并验证容器重启计数。

**Architecture:** 用 `kube-prometheus-stack` Helm chart 安装 Prometheus Operator、Prometheus、Alertmanager、Grafana、kube-state-metrics 和 node-exporter。所有监控组件放在 `monitoring` 命名空间，固定 requests/limits，Prometheus/Grafana/Alertmanager 使用 local-path PVC，通过 NodePort 暴露 UI。k3s 内嵌的 etcd/controller-manager/scheduler/kube-proxy 没有独立 metrics 端点，对应 ServiceMonitor 关闭，避免一堆永久 down 的 target。

**Tech Stack:** k3s `v1.36.5+k3s1`、Helm 3、kube-prometheus-stack、PromQL、Grafana、local-path。

**Spec:** `docs/02-lab/00-lab-design.md`

## Global Constraints

- 阶段 1 必须完成：三节点 `Ready`、系统 Pod `Running`、冒烟测试 `200`、LimitRange/Quota 生效、三台 VM 已有 `phase-1-k3s-ready` 快照。
- 所有长期运行的监控组件必须设置 `requests` 和 `limits`。
- 监控组件统一放在 `monitoring` 命名空间。
- Prometheus 保留 7 天，抓取间隔 15 秒，保留大小上限 6 GB。
- Prometheus、Alertmanager、Grafana 使用 `local-path` 存储。
- NodePort 规划：Grafana `30030`、Prometheus `30090`、Alertmanager `30093`。
- 不在仓库里记录 Grafana 密码、token 或私钥。
- 这是实验环境，Grafana/Prometheus 只通过内网 NodePort 访问，不暴露到公网。
- 不安装 Tempo/OTel；阶段 2 只做指标链路。

## Review Focus

- 6 GB server 上 Prometheus 1.2 GiB limit 是否够用；如果 OOM，先降保留期/保留大小，再考虑加内存。
- chart 默认组件是否都带 resources；没有显式 resources 的长期组件需要补。
- k3s 没有独立 etcd/controller-manager/scheduler/kube-proxy metrics，相关 ServiceMonitor 必须关闭，否则 Targets 页面会长期显示 down。
- NodePort 30030/30090/30093 是否与现有 Service 冲突。
- local-path PVC 是否 Bound；PVC Pending 时 Prometheus/Grafana 不会启动。
- Grafana 的 Prometheus 数据源和默认 Dashboard 是否自动 provisioning。
- 删除 Pod 和重启容器的语义不同：删除 Pod 会创建新 Pod，重启计数归零；要验证重启计数，必须让容器进程退出。
- Helm chart 版本与 k3s `v1.36.5` 的兼容性；安装前记录实际 chart 版本。

---

## Task 0: 阶段 1 收尾与快照

**Files:** 无

**Interfaces:**
- Consumes: 阶段 0–1 的三节点集群。
- Produces: 一个可以回滚的 `phase-1-k3s-ready` 快照，以及 LimitRange 默认值注入的证据。

- [ ] **Step 1: 确认集群仍然健康**

```bash
kubectl get nodes -o wide
kubectl get pods -A --no-headers | grep -Ev 'Running|Completed' || true
```

Expected: 三个节点 `Ready`；第二条命令没有输出。

- [x] **Step 2: 验证 LimitRange 默认值注入**

```bash
kubectl run quota-check -n demo --image=nginx:1.27-alpine --restart=Never
kubectl get pod quota-check -n demo -o jsonpath='{.spec.containers[0].resources}'; echo
kubectl delete pod quota-check -n demo
```

Expected: 输出包含 `requests.cpu=50m`、`requests.memory=64Mi`、`limits.cpu=500m`、`limits.memory=256Mi`。

- [ ] **Step 3: 打阶段 1 快照**

在 VMware 中给三台 VM 分别打快照，命名 `phase-1-k3s-ready`。快照前关机或暂停。

Expected: 三台 VM 的快照列表里都有 `phase-1-k3s-ready`。

- [ ] **Step 4: 更新阶段 1 验收文档**

把 `docs/02-lab/01-phase-0-1-acceptance.md` 里 LimitRange 注入和快照两个复选框改成 `[x]`，提交：

```bash
git add docs/02-lab/01-phase-0-1-acceptance.md
git commit -m "docs: complete phase 0-1 acceptance"
```

---

## Task 1: 安装 Helm 并添加 chart 仓库

**Files:** 无

**Interfaces:**
- Consumes: 能访问外网的 server。
- Produces: `helm` 命令、`prometheus-community` 仓库、实际使用的 chart 版本号。

- [ ] **Step 1: 检查 Helm 是否已安装**

```bash
helm version
```

Expected: 输出 `version.BuildInfo{Version:"v3...`。如果命令不存在，继续 Step 2。

- [ ] **Step 2: 安装 Helm**

```bash
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
bash /tmp/get_helm.sh
helm version
```

Expected: 安装成功，`helm version` 输出版本。

如果 GitHub raw 访问失败，用官方二进制作为备用：

```bash
curl -fsSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz
tar -zxvf /tmp/helm.tar.gz -C /tmp
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
helm version
```

- [ ] **Step 3: 添加 Prometheus 社区仓库**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Expected: 输出 `"prometheus-community" has been added` 和 `Update Complete.`。

- [ ] **Step 4: 选择并记录 chart 版本**

```bash
helm search repo prometheus-community/kube-prometheus-stack --versions | head -10
```

Expected: 输出 chart 版本列表。把选定的稳定版本记下来，例如：

```bash
export KPS_VERSION="<选定的版本>"
echo "$KPS_VERSION"
```

后面安装时用 `--version "$KPS_VERSION"`，保证可重复。

---

## Task 2: 写 monitoring values 文件

**Files:**
- Create: `infra/monitoring/values-kube-prometheus-stack.yaml`
- Copy to server: `/root/monitoring/values-kube-prometheus-stack.yaml`

**Interfaces:**
- Consumes: Task 1 的 Helm 仓库。
- Produces: 一份固定资源、存储和 NodePort 的 values 文件。

- [ ] **Step 1: 在仓库创建 values 文件**

```yaml
# kube-prometheus-stack values for the 3-node k3s lab
# Install namespace: monitoring
# NodePorts: Grafana 30030, Prometheus 30090, Alertmanager 30093

prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    replicas: 1
    retention: 7d
    retentionSize: 6GB
    scrapeInterval: 15s
    evaluationInterval: 15s
    walCompression: true
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 200m
        memory: 300Mi
      limits:
        cpu: "1"
        memory: 1200Mi
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 10Gi

alertmanager:
  service:
    type: NodePort
    nodePort: 30093
  alertmanagerSpec:
    replicas: 1
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi

grafana:
  service:
    type: NodePort
    nodePort: 30030
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
  persistence:
    enabled: true
    storageClassName: local-path
    size: 1Gi
  defaultDashboardsEnabled: true
  sidecar:
    dashboards:
      enabled: true

kubeStateMetrics:
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi

prometheus-node-exporter:
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

prometheusOperator:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# k3s 内嵌这些控制面组件，没有独立 metrics 端点
kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
```

- [ ] **Step 2: 在本地检查 YAML**

在仓库根目录：

```bash
helm lint prometheus-community/kube-prometheus-stack -f infra/monitoring/values-kube-prometheus-stack.yaml
```

Expected: `1 chart(s) linted, 0 chart(s) failed`。

> 如果本地 Windows 没有 helm，这一步在 server 上做，路径换成复制后的文件。

- [ ] **Step 3: 渲染一次，确认模板能生成**

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "$KPS_VERSION" \
  -f infra/monitoring/values-kube-prometheus-stack.yaml \
  > /tmp/kps-rendered.yaml
```

Expected: 退出码 0，`/tmp/kps-rendered.yaml` 非空。

- [ ] **Step 4: 复制到 server**

在 Windows PowerShell：

```powershell
scp -r E:\learn_aiops_sre\infra\monitoring root@172.25.254.10:/root/
```

在 server 上确认：

```bash
ls -l /root/monitoring/values-kube-prometheus-stack.yaml
```

- [ ] **Step 5: 提交 values 文件**

```bash
git add infra/monitoring/values-kube-prometheus-stack.yaml
git commit -m "feat: add kube-prometheus-stack values for lab"
```

---

## Task 3: 安装 kube-prometheus-stack

**Files:** 无

**Interfaces:**
- Consumes: Task 2 的 values 文件、Task 1 的 chart 版本。
- Produces: `monitoring` 命名空间里的 Prometheus、Alertmanager、Grafana、KSM、node-exporter、Operator。

- [ ] **Step 1: 安装 chart**

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version "$KPS_VERSION" \
  -f /root/monitoring/values-kube-prometheus-stack.yaml
```

Expected: 输出 `STATUS: deployed`。

- [ ] **Step 2: 观察 Pod 启动**

```bash
kubectl get pods -n monitoring -w
```

Expected: 主要组件变成 `Running`：

```text
alertmanager-kube-prometheus-stack-alertmanager-0
kube-prometheus-stack-grafana-...
kube-prometheus-stack-kube-state-metrics-...
kube-prometheus-stack-operator-...
kube-prometheus-stack-prometheus-node-exporter-...  （3 个，每节点一个）
prometheus-kube-prometheus-stack-prometheus-0
```

`kube-prometheus-stack-admission-create-*` 和 `admission-patch-*` 是 Job，`Completed` 是正常的。

全部 `Running` 后按 `Ctrl+C`。

- [ ] **Step 3: 检查 PVC**

```bash
kubectl get pvc -n monitoring
```

Expected: 三个 PVC 都是 `Bound`：

```text
prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0   10Gi
alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0   1Gi
kube-prometheus-stack-grafana   1Gi
```

- [ ] **Step 4: 检查 Service 和 NodePort**

```bash
kubectl get svc -n monitoring
```

Expected:

```text
kube-prometheus-stack-grafana      NodePort    ...   80:30030/TCP
kube-prometheus-stack-prometheus   NodePort    ...   9090:30090/TCP
kube-prometheus-stack-alertmanager NodePort    ...   9093:30093/TCP
```

- [ ] **Step 5: 失败时排查**

```bash
kubectl get events -n monitoring --sort-by=.lastTimestamp
kubectl describe pod -n monitoring <Pod名>
kubectl logs -n monitoring <Pod名> --tail=100
```

常见原因：

- 镜像拉取失败：worker/server 的 `registries.yaml` 是否包含 Prometheus/Grafana 镜像仓库。
- PVC Pending：`kubectl get storageclass` 看 `local-path` 是否存在。
- Prometheus OOMKilled：先降 `retention`/`retentionSize`，再考虑提高 limit。
- NodePort 冲突：换一个 30000–32767 的端口，改 values 后 `helm upgrade`。

---

## Task 4: 验证 Prometheus 目标和 PromQL

**Files:** 无

**Interfaces:**
- Consumes: Task 3 的 Prometheus。
- Produces: 节点、Pod、重启指标的查询证据。

- [ ] **Step 1: 检查 Prometheus CR 和 ServiceMonitor**

```bash
kubectl get prometheus -n monitoring
kubectl get servicemonitors -n monitoring
```

Expected: 存在 `prometheus-kube-prometheus-stack-prometheus`；ServiceMonitor 列表非空。

- [ ] **Step 2: 检查 Prometheus 自身就绪**

```bash
curl -s http://172.25.254.10:30090/-/ready
```

Expected:

```text
Prometheus Server is Ready.
```

- [ ] **Step 3: 查询 node-exporter 目标数**

```bash
curl -sG --data-urlencode 'query=count(up{job="node-exporter"} == 1)' \
  http://172.25.254.10:30090/api/v1/query
```

Expected: JSON 的 `value` 是 `"3"`。

- [ ] **Step 4: 查询 demo 的 Pod 数**

```bash
curl -sG --data-urlencode 'query=count(kube_pod_info{namespace="demo"})' \
  http://172.25.254.10:30090/api/v1/query
```

Expected: JSON 的 `value` 是 `"2"`。

- [ ] **Step 5: 查询节点 CPU 使用率**

```bash
curl -sG --data-urlencode 'query=100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)' \
  http://172.25.254.10:30090/api/v1/query
```

Expected: 返回 3 个 `instance` 的时间序列。

- [ ] **Step 6: 在 Prometheus UI 检查 Targets**

浏览器打开：

```text
http://172.25.254.10:30090
```

进入 `Status -> Targets`。预期：

- `node-exporter`：3 个 up
- `kubelet`：3 个 up
- `kube-state-metrics`：1 个 up
- `kube-apiserver`、`coredns`、`prometheus`：up
- 不出现 etcd/controller-manager/scheduler/kube-proxy 的永久 down target

---

## Task 5: 验证 Grafana

**Files:** 无

**Interfaces:**
- Consumes: Task 3 的 Grafana、Task 4 的 Prometheus。
- Produces: Grafana 登录、数据源和 Dashboard 的验证证据。

- [ ] **Step 1: 取 Grafana admin 密码**

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

如果 secret 名字不同：

```bash
kubectl get secret -n monitoring | grep grafana
```

- [ ] **Step 2: 登录 Grafana**

浏览器打开：

```text
http://172.25.254.10:30030
```

用户名 `admin`，密码用上一步的输出。

- [ ] **Step 3: 检查 Prometheus 数据源**

进入 `Connections -> Data sources -> Prometheus`，点 `Save & test`。

Expected: `Data source is working`。

- [ ] **Step 4: 检查 Dashboard**

进入 `Dashboards`，打开：

- `Kubernetes / Compute Resources / Cluster`
- `Node Exporter / Nodes`

Expected:

- 能看到 3 个节点。
- 能看到 `demo` 命名空间的两个 `web` Pod。
- 时间范围选 `Last 15 minutes` 时曲线有数据。

- [ ] **Step 5: 在 Explore 里跑三条 PromQL**

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

```promql
sum by (namespace, pod) (container_memory_working_set_bytes{namespace="demo", container!="", container!="POD"})
```

```promql
kube_pod_container_status_restarts_total{namespace="demo"}
```

Expected: 三条查询都有结果；重启计数初始为 `0`。

---

## Task 6: 验证重启计数

**Files:** 无

**Interfaces:**
- Consumes: Task 4 的 Prometheus、Task 5 的 Grafana。
- Produces: 容器重启计数从 0 变 1 的证据，以及“删除 Pod 会创建新 Pod”的对比证据。

- [ ] **Step 1: 找到 demo 的 web Pod**

```bash
kubectl get pods -n demo -o wide
```

记下一个 `web-...` Pod 名字。

- [ ] **Step 2: 让容器进程退出**

```bash
kubectl exec -n demo <web-pod> -- kill 1
```

Expected: 命令可能因为连接断开而报错，这是正常的；容器会被 kubelet 重启。

- [ ] **Step 3: 观察 RESTARTS 增加**

```bash
kubectl get pods -n demo -w
```

Expected: 对应 Pod 的 `RESTARTS` 从 `0` 变成 `1`。按 `Ctrl+C`。

- [ ] **Step 4: 用 Prometheus 查询重启计数**

```bash
curl -sG --data-urlencode 'query=kube_pod_container_status_restarts_total{namespace="demo"}' \
  http://172.25.254.10:30090/api/v1/query
```

Expected: 对应容器的 value 至少为 `"1"`。

- [ ] **Step 5: 对比“删除 Pod”**

```bash
kubectl delete pod -n demo <另一个-web-pod>
kubectl get pods -n demo -w
```

Expected: 出现一个新的 `web-...` Pod，名字不同；新 Pod 的重启计数从 `0` 开始。

这说明：

- 删除 Pod 是“换一个 Pod”，不是“重启容器”。
- 重启计数要看 `kube_pod_container_status_restarts_total`，并且要触发容器退出。

- [ ] **Step 6: 在 Grafana Explore 里确认**

在 Grafana Explore 里运行：

```promql
kube_pod_container_status_restarts_total{namespace="demo"}
```

Expected: 能看到刚重启的容器值为 `1`。

---

## Task 7: 阶段 2 验收文档与快照

**Files:**
- Create: `docs/02-lab/02-phase-2-acceptance.md`

**Interfaces:**
- Consumes: Task 3–6 的全部结果。
- Produces: 阶段 2 验收记录和 `phase-2-metrics-ready` 快照。

- [ ] **Step 1: 收集验收输出**

在 server 上：

```bash
helm list -n monitoring
kubectl get pods -n monitoring -o wide
kubectl get pvc -n monitoring
kubectl get svc -n monitoring
kubectl get prometheus -n monitoring
kubectl top nodes
kubectl top pods -n monitoring
free -h
df -h
```

在 Prometheus/Grafana 里记录：

- `count(up{job="node-exporter"} == 1)` 的结果
- `count(kube_pod_info{namespace="demo"})` 的结果
- 重启计数查询的前后值
- Grafana 能打开的 Dashboard 名称

- [ ] **Step 2: 写验收文档**

`docs/02-lab/02-phase-2-acceptance.md` 至少包含：

- 实际安装的 chart 版本
- `monitoring` 的 Pod 和 PVC 状态
- Prometheus Targets 摘要
- 三条 PromQL 的结果
- Grafana 访问地址、Dashboard 名称
- 重启计数验证结果
- 安装后的内存/磁盘余量
- 与计划的偏差
- 下一步（阶段 3：日志链路）的前置条件

- [ ] **Step 3: 打快照**

在 VMware 中给三台 VM 分别打快照，命名：

```text
phase-2-metrics-ready
```

- [ ] **Step 4: 提交**

```bash
git add docs/02-lab/02-phase-2-acceptance.md
git commit -m "docs: record phase 2 metrics acceptance"
```

---

## 完成标准

- `monitoring` 里的 Prometheus、Grafana、Alertmanager、KSM、node-exporter 全部 `Running`。
- 三个 PVC 都是 `Bound`。
- Prometheus Targets 里 node-exporter 3 个 up，kubelet 3 个 up，KSM 1 个 up。
- Grafana 能打开节点和集群 Dashboard，能看到 3 个节点和 demo 的 Pod。
- 能查到节点 CPU、Pod 内存、容器重启计数。
- 容器重启后 `kube_pod_container_status_restarts_total` 从 0 变 1。
- server 可用内存仍大于 1 GB，worker 大于 800 MB。
- 三台 VM 都有 `phase-2-metrics-ready` 快照。
