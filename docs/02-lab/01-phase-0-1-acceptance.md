# 阶段 0–1 验收记录

> 状态：等待在 VMware 上执行。执行完成后，把每个 `<待填写>` 替换成真实输出，再提交。

## 环境

| 项 | 值 |
|---|---|
| 宿主机 | Windows，16 GB 内存，14 核 20 线程 |
| VMware 网络 | `VMnet8`，`172.25.254.0/24`，网关 `172.25.254.2` |
| `k8s-server` | `172.25.254.10/24` |
| `k8s-worker-1` | `172.25.254.11/24` |
| `k8s-worker-2` | `172.25.254.12/24` |
| 系统 | Ubuntu Server 24.04 LTS |
| 集群 | k3s stable |

## 验收清单

- [ ] 三台虚拟机安装完成，静态 IP 和主机名正确
- [ ] `kubectl get nodes` 三节点全部 `Ready`
- [ ] `demo/web` 两个 Pod 在不同节点运行
- [ ] `curl http://172.25.254.10:30080` 返回 `200`
- [ ] `demo` 的 LimitRange 默认值生效
- [ ] `demo` 的 ResourceQuota 生效
- [ ] 三台虚拟机都有快照 `phase-1-k3s-ready`

## 收集命令

在 server 上：

```bash
kubectl version
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc -A
kubectl get pods -n demo -o wide
curl -I http://172.25.254.10:30080
kubectl describe limitrange -n demo
kubectl describe quota -n demo
free -h
df -h
systemctl status k3s --no-pager
```

在两个 worker 上：

```bash
free -h
df -h
systemctl status k3s-agent --no-pager
```

## 结果

### k3s 版本

```text
<待填写>
```

### 节点

```text
<待填写：kubectl get nodes -o wide>
```

### 系统 Pod

```text
<待填写：kubectl get pods -A -o wide>
```

### 冒烟测试

```text
<待填写：kubectl get pods -n demo -o wide>
<待填写：curl -I 输出>
```

### 资源基线与配额

```text
<待填写：kubectl describe limitrange -n demo>
<待填写：kubectl describe quota -n demo>
```

### 内存与磁盘余量

```text
<待填写：三台机器的 free -h 和 df -h>
```

要求：server 可用内存大于 1 GB，worker 大于 800 MB。低于这个值，阶段 2 装 Prometheus 和 Loki 会 OOM。

## 与计划的偏差

<待填写：例如网卡名不是 ens33、IP 段不同、安装器内存不足等>

## 下一步

阶段 2：指标链路。

- 安装 kube-prometheus-stack
- 给所有组件设置 requests/limits
- 导入 Node Exporter 和集群面板
- 写 PromQL 并配置第一条告警

前置条件：三节点 Ready，且内存余量满足上面的要求。
