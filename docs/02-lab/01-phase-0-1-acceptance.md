# 阶段 0–1 验收记录

> 状态：集群底座、冒烟测试、资源基线和 LimitRange 默认值注入已通过；待补充三台 VM 快照。

## 环境

| 项 | 值 |
|---|---|
| 宿主机 | Windows，16 GB 内存，14 核 20 线程 |
| VMware 网络 | `VMnet8`，`172.25.254.0/24`，网关 `172.25.254.2` |
| `k8s-server` | `172.25.254.10/24` |
| `k8s-worker-1` | `172.25.254.11/24` |
| `k8s-worker-2` | `172.25.254.12/24` |
| 系统 | Ubuntu Server 22.04.5 LTS |
| 内核 | `6.8.0-138-generic` |
| 集群 | k3s `v1.36.5+k3s1` |
| 容器运行时 | `containerd://2.3.4-k3s1.36` |
| VM 内存 | server 6 GB，两个 worker 各 3 GB |

## 验收清单

- [x] 三台虚拟机安装完成，静态 IP 和主机名正确
- [x] `kubectl get nodes` 三节点全部 `Ready`
- [x] `demo/web` 两个 Pod 在不同节点运行
- [x] `curl http://172.25.254.10:30080` 返回 `200`
- [x] `demo` 的 LimitRange 默认值注入已验证
- [x] `demo` 的 ResourceQuota 生效
- [ ] 三台虚拟机都有快照 `phase-1-k3s-ready`

## 结果

### k3s 版本

```text
Client Version: v1.36.5+k3s1
Kustomize Version: v5.8.1
Server Version: v1.36.5+k3s1
```

### 节点

```text
NAME           STATUS   ROLES           AGE   VERSION        INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
k8s-server     Ready    control-plane   87m   v1.36.5+k3s1   172.25.254.10   <none>        Ubuntu 22.04.5 LTS   6.8.0-138-generic (amd64)   containerd://2.3.4-k3s1.36
k8s-worker-1   Ready    <none>          68m   v1.36.5+k3s1   172.25.254.11   <none>        Ubuntu 22.04.5 LTS   6.8.0-138-generic (amd64)   containerd://2.3.4-k3s1.36
k8s-worker-2   Ready    <none>          64m   v1.36.5+k3s1   172.25.254.12   <none>        Ubuntu 22.04.5 LTS   6.8.0-138-generic (amd64)   containerd://2.3.4-k3s1.36
```

### 系统 Pod

```text
NAMESPACE     NAME                                      READY   STATUS    RESTARTS      AGE   IP           NODE
demo          web-554647c847-42l4t                      1/1     Running   0             30m   10.42.1.4    k8s-worker-1
demo          web-554647c847-n44bz                      1/1     Running   0             30m   10.42.2.4    k8s-worker-2
kube-system   coredns-7cfb7bc9c7-h995l                  1/1     Running   1 (38m ago)   76m   10.42.0.78   k8s-server
kube-system   local-path-provisioner-77b9867795-pf6rk   1/1     Running   1 (38m ago)   76m   10.42.0.77   k8s-server
kube-system   metrics-server-6dc596dfb8-65nlt           1/1     Running   1 (38m ago)   76m   10.42.0.75   k8s-server
kube-system   svclb-traefik-f37c25d8-2vgtn              2/2     Running   2 (38m ago)   76m   10.42.0.74   k8s-server
kube-system   svclb-traefik-f37c25d8-dg294              2/2     Running   2 (37m ago)   64m   10.42.2.3    k8s-worker-2
kube-system   svclb-traefik-f37c25d8-jnrhp              2/2     Running   2 (37m ago)   68m   10.42.1.3    k8s-worker-1
kube-system   traefik-7c8544f77-zrsvc                   1/1     Running   1 (38m ago)   76m   10.42.0.76   k8s-server
```

> `coredns`、`local-path`、`metrics-server`、`traefik`、`svclb-traefik` 的 `RESTARTS` 是之前修复 pause 镜像、重启 k3s 时产生的；当前全部 `Running`。

### Service

```text
NAMESPACE     NAME             TYPE           CLUSTER-IP     EXTERNAL-IP                                 PORT(S)
default       kubernetes       ClusterIP      10.43.0.1      <none>                                      443/TCP
demo          web              NodePort       10.43.1.146    <none>                                      80:30080/TCP
kube-system   kube-dns         ClusterIP      10.43.0.10     <none>                                      53/UDP,53/TCP,9153/TCP
kube-system   metrics-server   ClusterIP      10.43.4.4      <none>                                      443/TCP
kube-system   traefik          LoadBalancer   10.43.250.96   172.25.254.10,172.25.254.11,172.25.254.12   80:31964/TCP,443:32564/TCP
```

### 冒烟测试

```text
NAME                   READY   STATUS    RESTARTS   AGE   IP          NODE
web-554647c847-42l4t   1/1     Running   0          30m   10.42.1.4   k8s-worker-1
web-554647c847-n44bz   1/1     Running   0          30m   10.42.2.4   k8s-worker-2
```

```text
HTTP/1.1 200 OK
Server: nginx/1.27.5
Date: Wed, 21 Oct 2026 10:26:00 GMT
Content-Type: text/html
Content-Length: 615
Last-Modified: Wed, 16 Apr 2025 12:55:34 GMT
Connection: keep-alive
ETag: "67ffa8c6-267"
Accept-Ranges: bytes
```

两个 `web` Pod 分别落在 `k8s-worker-1` 和 `k8s-worker-2`，Windows 主机访问 `http://172.25.254.10:30080` 返回 `200`。

### 资源基线与配额

```text
Name:       default-limits
Namespace:  demo
Type        Resource  Min  Max  Default Request  Default Limit  Max Limit/Request Ratio
----        --------  ---  ---  ---------------  -------------  -----------------------
Container   cpu       -    1    50m              500m           -
Container   memory    -    1Gi  64Mi             256Mi          -
```

```text
Name:            demo-quota
Namespace:       demo
Resource         Used   Hard
--------         ----   ----
limits.cpu       400m   4
limits.memory    256Mi  4Gi
pods             2      20
requests.cpu     100m   2
requests.memory  128Mi  2Gi
```

Quota 的 `Used` 正好对应两个 `web` Pod：

```text
每个 web：
  requests: 50m CPU / 64Mi
  limits:   200m CPU / 128Mi

两个 web：
  requests: 100m CPU / 128Mi
  limits:   400m CPU / 256Mi
  pods:     2
```

LimitRange 的默认值已通过临时 Pod 验证：创建 `quota-check` 时没有写 `resources`，Pod 的容器自动获得 `requests 50m/64Mi`、`limits 500m/256Mi`。删除后配额回到基线。

### 内存与磁盘余量

| 节点 | Mem total | Mem used | Mem available | Disk size | Disk used | Disk avail | Disk use% |
|---|---|---|---|---|---|---|---|
| `k8s-server` | 5.7 GiB | 1.3 GiB | 4.2 GiB | 98 GB | 12 GB | 81 GB | 13% |
| `k8s-worker-1` | 2.9 GiB | 695 MiB | 2.0 GiB | 98 GB | 12 GB | 82 GB | 13% |
| `k8s-worker-2` | 2.9 GiB | 699 MiB | 2.0 GiB | 98 GB | 12 GB | 82 GB | 13% |

要求：server 可用内存大于 1 GB，worker 大于 800 MB。三台都满足：

- server `available`：4.2 GiB
- worker-1 `available`：2.0 GiB
- worker-2 `available`：2.0 GiB

### systemd 状态

| 节点 | 服务 | 状态 | 进程内存 |
|---|---|---|---|
| `k8s-server` | `k3s` | `active (running)` | 843.3 MiB |
| `k8s-worker-1` | `k3s-agent` | `active (running)` | 402.1 MiB |
| `k8s-worker-2` | `k3s-agent` | `active (running)` | 404.0 MiB |

## 与计划的偏差

1. **系统版本**：计划写的是 Ubuntu Server 24.04 LTS，实际安装的是 Ubuntu 22.04.5 LTS。k3s 和内核参数检查都通过，不影响阶段 1 验收。
2. **worker 内存**：计划是每个 worker 2 GB，实际 `free -h` 显示约 2.9 GiB，说明 VM 配置更接近 3 GB。内存余量更充足，不需要调整。
3. **k3s 版本**：实际安装的是 `v1.36.5+k3s1`，属于安装时的 stable 版本。
4. **Traefik Service 的 EXTERNAL-IP**：显示三个节点 IP，这是 k3s `servicelb` 的正常行为，不是配置错误。
5. **kubelet 日志**：worker 日志在删除临时容器时出现过 `failed to read memory cgroup ...` 和 `ContainerStatus from runtime service failed` 的瞬时错误；节点仍然 `Ready`，业务 Pod 正常。阶段 2 继续观察是否重复出现。

## 待完成

- [x] 运行临时 Pod，记录 LimitRange 默认值注入结果。
- [ ] 三台 VM 打快照 `phase-1-k3s-ready`。

### LimitRange 默认值注入验证命令

在 server 上：

```bash
kubectl run quota-check -n demo --image=nginx:1.27-alpine --restart=Never
```

```bash
kubectl get pod quota-check -n demo -o jsonpath='{.spec.containers[0].resources}'; echo
```

预期：

```json
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

```bash
kubectl describe quota -n demo
```

预期 `Used` 从 2 个 Pod 变成 3 个，requests 变为约 `150m/192Mi`，limits 变为约 `900m/512Mi`。

```bash
kubectl delete pod quota-check -n demo
```

实际结果（2026-10-21）：

```text
创建 quota-check 后：
pods 3，requests 150m/192Mi，limits 900m/512Mi

删除 quota-check 后：
pods 2，requests 100m/128Mi，limits 400m/256Mi
```

说明默认值确实注入到了临时 Pod，并且删除后配额恢复。

### 快照

在 VMware 中给三台虚拟机分别打快照，命名 `phase-1-k3s-ready`。快照前先关机或暂停，避免磁盘状态不一致。

## 下一步

阶段 2：指标链路。

- 安装 kube-prometheus-stack
- 给所有组件设置 requests/limits
- 导入 Node Exporter 和集群面板
- 写 PromQL 并配置第一条告警

前置条件：三节点 `Ready`，内存余量满足要求，LimitRange 注入验证通过，快照完成。
