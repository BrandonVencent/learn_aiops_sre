# 学习问答记录

> 记录时间：2026-10-21
> 环境：Windows + VMware，Ubuntu Server 24.04 LTS，k3s 三节点
> 约定：后续问答按日期追加到本文末尾；命令保留可复制形式；不记录 token、密码等敏感信息。

这篇文档记录搭建 k3s 实验环境过程中真实遇到的问题、当时的回答和可复现的命令。它不是教程的替代品，而是用来回答「当时为什么这么做」。内容按问答整理，保留问题、结论、命令和验证方式，不完全逐字复刻聊天原文。

## 当前进度（截至 2026-10-21）

- 三台 VM 的基线配置已完成：静态 IP、hostname、hosts、swap、内核模块、sysctl、apt、ufw。
- `k8s-server` 已安装 k3s server。
- 当前卡在系统镜像拉取：`rancher/mirrored-pause:3.10.2` 拉取失败，导致 CoreDNS、local-path-provisioner、metrics-server 无法启动。
- 下一步：配置 Docker Hub 镜像加速，重启 k3s，确认系统 Pod 全部 `Running`，再加入两个 worker。

## 目录

1. [sysctl 的 Invalid argument 要不要管](#1-sysctl-的-invalid-argument-要不要管)
2. [国内镜像安装命令能不能用](#2-国内镜像安装命令能不能用)
3. [pause 镜像拉不到怎么办](#3-pause-镜像拉不到怎么办)
4. [什么时候加入 worker，三台都跑 server 吗](#4-什么时候加入-worker三台都跑-server-吗)
5. [k3s 的网络是怎么通的，为什么看不到 Flannel](#5-k3s-的网络是怎么通的为什么看不到-flannel)

---

## 1. sysctl 的 Invalid argument 要不要管

### 问题

执行 `sysctl --system` 时出现：

```text
sysctl: setting key "net.ipv4.conf.all.accept_source_route": Invalid argument
sysctl: setting key "net.ipv4.conf.all.promote_secondaries": Invalid argument
```

是不是 k8s 的内核参数配错了？

### 结论

不是。这两行来自 Ubuntu 自带的 `/usr/lib/sysctl.d/50-default.conf`，和 k8s 无关。我们写入 `/etc/sysctl.d/k8s.conf` 的三项已经生效：

```text
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
```

### 验证

```bash
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
```

预期输出三个 `= 1`。

```bash
swapon --show
```

没有输出，说明 swap 已关闭。

### 顺带修正

`sysctl --system` 遇到 Ubuntu 自带的无关报错时会返回非零。如果脚本里有 `set -e`，会在这里提前退出。所以基线脚本改成只应用 k8s 自己的配置文件：

```bash
sysctl -p /etc/sysctl.d/k8s.conf
```

对应提交：`48f50de fix: apply only the k8s sysctl file`。

---

## 2. 国内镜像安装命令能不能用

### 问题

```bash
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -
```

这条可以吗？

### 结论

可以。不写 `server` 时，k3s 安装脚本默认也按 server 安装。建议显式写成 `sh -s - server`，避免以后看命令时产生歧义。

```bash
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -s - server
```

### 运行前先确认配置

```bash
cat /etc/rancher/k3s/config.yaml
```

应该包含：

```yaml
write-kubeconfig-mode: "0644"
node-ip: "172.25.254.10"
tls-san:
  - "172.25.254.10"
  - "k8s-server"
```

没有的话先创建：

```bash
mkdir -p /etc/rancher/k3s
```

```bash
tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
write-kubeconfig-mode: "0644"
node-ip: "172.25.254.10"
tls-san:
  - "172.25.254.10"
  - "k8s-server"
EOF
```

### 注意

`INSTALL_K3S_MIRROR=cn` 只影响 k3s 安装包、二进制和校验文件的下载地址，**不会配置容器镜像仓库**。系统镜像默认还是从 `docker.io` 拉取，这是下一节问题的根因。

---

## 3. pause 镜像拉不到怎么办

### 问题

k3s server 安装完成后，Pod 报错：

```text
failed to pull image "rancher/mirrored-pause:3.10.2"
CreatePodSandbox
```

受影响的有 CoreDNS、local-path-provisioner、metrics-server。

### 结论

是镜像拉取失败，不是 k3s 安装失败。

`rancher/mirrored-pause:3.10.2` 是每个 Pod 的沙箱基础镜像。kubelet 创建 Pod 时先用它建 sandbox；它拉不到，后面的容器都起不来。

`INSTALL_K3S_MIRROR=cn` 只加速 k3s 自身下载，不会改容器镜像仓库。Docker Hub 在国内经常超时，所以需要给 containerd 配一个 Docker Hub 镜像加速器。

### 修复

在 server 上执行：

```bash
mkdir -p /etc/rancher/k3s
```

```bash
tee /etc/rancher/k3s/registries.yaml >/dev/null <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1ms.run"
EOF
```

字段含义：

- `mirrors.docker.io`：所有 `docker.io/...` 的镜像先走下面的地址。
- `endpoint`：按顺序尝试，第一个失败会用第二个。
- 这是 k3s 内置 containerd 的配置，不是 Docker 的 `daemon.json`。

重启 k3s：

```bash
systemctl restart k3s
```

等 20～30 秒，清理失败的 Pod：

```bash
kubectl delete pod -n kube-system --all
```

观察重建：

```bash
kubectl get pods -n kube-system -w
```

看到 `ContainerCreating` 变成 `Running` 就正常。按 `Ctrl+C` 退出。

### 验证

```bash
kubectl get nodes -o wide
```

```bash
kubectl get pods -A -o wide
```

预期：

- `k8s-server` 是 `Ready`
- `kube-system` 里的 CoreDNS、local-path、metrics-server、Traefik 都是 `Running`

### 如果还是失败

先看具体是哪个镜像、报什么错：

```bash
kubectl describe pod -n kube-system <Pod名>
```

或者看 k3s 日志：

```bash
journalctl -u k3s -n 100 --no-pager
```

备用镜像端点：

```bash
tee /etc/rancher/k3s/registries.yaml >/dev/null <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://dockerproxy.net"
      - "https://docker.m.daocloud.io"
EOF
```

```bash
systemctl restart k3s
```

```bash
kubectl delete pod -n kube-system --all
```

`dockerproxy.net` 是临时公共镜像，稳定性不如前两个，只作为备用。

### 重要提醒

每台 worker 加入集群前也要写同样的 `/etc/rancher/k3s/registries.yaml`。worker 也要拉 pause、Flannel 等镜像，只配 server 不够。

---

## 4. 什么时候加入 worker，三台都跑 server 吗

### 问题

是不是漏了加入 worker 的步骤？还是三台都执行 `sh -s - server` 就可以？

### 结论

没有漏。worker 要等 server 的镜像问题解决、系统 Pod 正常后再加。原因是 worker 加入时也要拉 pause、Flannel 等镜像；server 的镜像仓库没配好，worker 加进来也会一样报错。

**三台都跑 `server` 是错的。** 那样会变成三个互相独立的集群，不是一主两从。

| 机器 | 角色 | 安装命令关键部分 |
|---|---|---|
| `k8s-server` | 控制面 | `sh -s - server` |
| `k8s-worker-1` | 工作节点 | `sh -s - agent --server ... --token ...` |
| `k8s-worker-2` | 工作节点 | `sh -s - agent --server ... --token ...` |

### 正确顺序

1. 修好 server 的镜像拉取。
2. 确认 `kubectl get pods -n kube-system` 都是 `Running`。
3. 加入 worker-1。
4. 加入 worker-2。
5. 回 server 确认三个节点 `Ready`。

### worker-1

先配镜像加速：

```bash
mkdir -p /etc/rancher/k3s
```

```bash
tee /etc/rancher/k3s/registries.yaml >/dev/null <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1ms.run"
EOF
```

写节点 IP：

```bash
tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
node-ip: "172.25.254.11"
EOF
```

在 **server** 上取 token：

```bash
cat /var/lib/rancher/k3s/server/node-token
```

复制输出的 token，回到 **worker-1**：

```bash
read -r -s TOKEN; echo
```

粘贴 token，回车。

```bash
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -s - agent --server https://172.25.254.10:6443 --token "$TOKEN"
```

检查：

```bash
systemctl status k3s-agent --no-pager
```

看到 `active (running)` 就说明 agent 起来了。

> worker 上没有 kubeconfig，不要在 worker 上跑 `kubectl`。回 server 看节点。

### worker-2

和 worker-1 一样，只改 `node-ip` 为 `172.25.254.12`，token 用同一个。

```bash
mkdir -p /etc/rancher/k3s
```

```bash
tee /etc/rancher/k3s/registries.yaml >/dev/null <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1ms.run"
EOF
```

```bash
tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
node-ip: "172.25.254.12"
EOF
```

```bash
read -r -s TOKEN; echo
```

粘贴同一个 token。

```bash
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -s - agent --server https://172.25.254.10:6443 --token "$TOKEN"
```

```bash
systemctl status k3s-agent --no-pager
```

### 验收

回 server：

```bash
kubectl get nodes -o wide
```

```bash
kubectl get pods -A -o wide
```

预期三个节点都是 `Ready`，`kube-system` 的 Pod 都是 `Running`。

如果 worker 一直没出现，在 worker 上看：

```bash
journalctl -u k3s-agent -n 50 --no-pager
```

常见原因：

- token 粘错或为空
- `--server` 的 IP 写错
- server 的 6443 端口不通

在 worker 上测端口：

```bash
curl -k https://172.25.254.10:6443/cacerts
```

能返回证书内容就说明网络通。

---

## 5. k3s 的网络是怎么通的，为什么看不到 Flannel

### 问题

节点和 Pod 之间怎么通信？为什么不像 kubeadm 那样还要装 Flannel 或 Calico？是已经装了但我不会看吗？

### 结论

对，已经装了，只是查看方式不一样。

k3s 默认把 **Flannel** 编进了 k3s 进程，所以它不以 Pod 形式运行。`kubectl get pods -n kube-system` 里看不到 `kube-flannel-ds`，这是正常的。k3s 同样把 kube-proxy 编进了进程，所以也看不到 `kube-proxy` Pod。

### 三层网络

| 网络 | 默认网段 | 作用 |
|---|---|---|
| 节点网络 | `172.25.254.0/24` | 三台 VM 之间通信，server `.10`，worker `.11/.12` |
| Pod 网络 | `10.42.0.0/16` | 每个 Pod 的 IP，Flannel 分配 |
| Service 网络 | `10.43.0.0/16` | ClusterIP，虚拟 IP，DNS 是 `10.43.0.10` |

每台节点会从 Pod 网段分到一个 `/24`，例如：

- server：`10.42.0.0/24`
- worker-1：`10.42.1.0/24`
- worker-2：`10.42.2.0/24`

具体分配可以看：

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
```

### 同节点 Pod 通信

同一个节点上的两个 Pod 走本地网桥，不封装：

```text
Pod A
  │ veth
cni0 网桥
  │ veth
Pod B
```

`cni0` 是节点上的网桥，Pod 的 veth 一端插在网桥上。节点上还没有 Pod 时，`cni0` 可能还不存在。

### 跨节点 Pod 通信

假设 worker-1 上的 Pod A 要访问 worker-2 上的 Pod B：

```text
Pod A  10.42.1.5
  │
  ▼
cni0   10.42.1.1
  │  路由：10.42.2.0/24 dev flannel.1
  ▼
flannel.1  （VXLAN 封装）
  │
  │  外层：172.25.254.11 -> 172.25.254.12
  │  协议：UDP 8472
  ▼
worker-2 的 flannel.1（解封装）
  │
  ▼
cni0   10.42.2.1
  │
  ▼
Pod B  10.42.2.7
```

关键点：

- **内层**是 Pod IP：`10.42.1.5 -> 10.42.2.7`
- **外层**是节点 IP：`172.25.254.11 -> 172.25.254.12`
- Flannel 把 Pod 的原始数据包整个塞进 VXLAN，再用节点网络送过去
- 所以节点之间必须能通 **UDP 8472**

### Pod 访问 Service

Service 的 ClusterIP 是虚拟的，没有网卡，靠 kube-proxy 写 iptables 规则。

例如 Pod 访问 CoreDNS：

```text
Pod
  │ 访问 10.43.0.10:53
  ▼
iptables 规则（kube-proxy 写入）
  │ DNAT
  ▼
CoreDNS Pod 的真实 IP，比如 10.42.0.8:53
  │
  ▼
走上面的 Pod 网络
```

### 外部访问

两种常见方式：

1. **NodePort**：例如冒烟测试的 `30080`，访问 `172.25.254.10:30080`，iptables 会把流量 DNAT 到 Pod。
2. **Traefik Ingress**：k3s 默认自带 Traefik，`svclb-traefik` 这个 DaemonSet 会在每台节点上用 hostPort 监听 80/443，把流量转给 Traefik Pod。

### 为什么和 kubeadm 不一样

| | kubeadm | k3s |
|---|---|---|
| CNI | 要自己装 Flannel/Calico | 默认自带 Flannel |
| Flannel 形态 | 通常是 `kube-flannel-ds` Pod | 编进 k3s 进程，不是 Pod |
| kube-proxy | 通常是 Pod | 编进 k3s 进程 |
| 查看方式 | `kubectl get pods -n kube-system` | `ip a` 看 `flannel.1`，`ss` 看 8472 |

### 想换 Calico 可以吗

可以，但实验没必要。做法是安装 k3s 时关掉 Flannel：

```bash
--flannel-backend=none --disable-network-policy
```

然后再装 Calico。Calico 更适合需要 BGP、复杂 NetworkPolicy 的场景；三台 VM 的实验，Flannel 足够，而且更轻。

k3s 默认还带了一个基于 kube-router 的网络策略控制器，所以基本的 NetworkPolicy 也能用。

### 验证命令

在 server 上：

```bash
kubectl get nodes -o wide
```

```bash
kubectl get pods -n kube-system -o wide
```

```bash
kubectl get svc -A
```

```bash
kubectl get endpointslices -A
```

```bash
kubectl get ds -n kube-system
```

在节点上：

```bash
ip -br a
```

```bash
ip route
```

```bash
ss -lunp | grep 8472
```

预期能看到：

- `flannel.1` 网卡
- `10.42.x.0/24 via 10.42.x.0 dev flannel.1` 这样的路由
- Flannel 监听 UDP 8472

---

## 后续记录约定

- 每次有新的问题，在本文末尾追加一节，标题格式：`## N. 日期 + 问题摘要`。
- 每节至少保留：问题、结论、原因/原理、可复现命令、验证方式。
- 涉及 token、密码、私钥时只写「在 server 上取 token」，不记录真实值。
- 如果问题跨多个阶段，优先放在本文，方便按时间回看；需要展开成专题时，再在 `docs/01-principles/` 或 `docs/02-lab/` 下新建文档，并在本文留链接。
