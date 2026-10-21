# 学习问答记录

> 记录时间：2026-10-21
> 环境：Windows + VMware，Ubuntu Server 24.04 LTS，k3s 三节点
> 当前 server 用户：root；server 上的命令默认不需要 `sudo`。
> 约定：后续问答按日期追加到本文末尾；命令保留可复制形式；不记录 token、密码等敏感信息。

这篇文档记录搭建 k3s 实验环境过程中真实遇到的问题、当时的回答和可复现的命令。它不是教程的替代品，而是用来回答「当时为什么这么做」。内容按问答整理，保留问题、结论、命令和验证方式，不完全逐字复刻聊天原文。

## 当前进度（截至 2026-10-21）

- 三台 VM 的基线配置已完成：静态 IP、hostname、hosts、swap、内核模块、sysctl、apt、ufw。
- `k8s-server` 已安装 k3s server。
- 镜像加速已配置，worker-1、worker-2 已加入；用户报告三节点都是 `Ready`。
- 冒烟测试已通过：Windows 主机可访问任意节点 IP:30080，能看到 nginx 欢迎页。
- 下一步：应用并验证命名空间、LimitRange、ResourceQuota（第 9 节），然后收集阶段 0–1 验收输出并打快照。

## 目录

1. [sysctl 的 Invalid argument 要不要管](#1-sysctl-的-invalid-argument-要不要管)
2. [国内镜像安装命令能不能用](#2-国内镜像安装命令能不能用)
3. [pause 镜像拉不到怎么办](#3-pause-镜像拉不到怎么办)
4. [什么时候加入 worker，三台都跑 server 吗](#4-什么时候加入-worker三台都跑-server-吗)
5. [k3s 的网络是怎么通的，为什么看不到 Flannel](#5-k3s-的网络是怎么通的为什么看不到-flannel)
6. [下一步做什么](#6-下一步做什么)
7. [三节点 Ready 之后先做什么](#7-三节点-ready-之后先做什么)
8. [冒烟测试和 smoke-test.yaml 是什么](#8-冒烟测试和-smoke-testyaml-是什么)
9. [冒烟测试通过后做什么](#9-冒烟测试通过后做什么)
10. [更正：server 当前使用 root](#10-更正server-当前使用-root)
11. [三个资源 YAML 逐行解释](#11-三个资源-yaml-逐行解释)
12. [资源清单解释完之后下一步做什么](#12-资源清单解释完之后下一步做什么)

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

## 6. 下一步做什么

### 问题

k3s server 已经装好了，但系统 Pod 因为镜像拉取失败没起来。下一步是先加 worker，还是先修 server？

### 结论

**先修 server 的镜像，不要先加 worker。**

worker 加入集群时同样要拉 pause、Flannel 等镜像。server 的镜像源没配好，worker 加进来也会一样失败，只会多一台有问题的节点。

正确顺序：

1. server 写 `registries.yaml`
2. 重启 k3s
3. 删除失败的 `kube-system` Pod
4. 确认 `kube-system` 全部 `Running`
5. 加入 worker-1
6. 加入 worker-2
7. 回 server 确认三节点 `Ready`

### 第 1 步：确认当前状态

在 server 上：

```bash
kubectl get nodes -o wide
```

```bash
kubectl get pods -A -o wide
```

预期：

- `k8s-server` 是 `Ready`
- `kube-system` 里有 Pod 处于 `ImagePullBackOff` 或 `ErrImagePull`

如果节点本身是 `NotReady`，先不要往下走，检查：

```bash
systemctl status k3s --no-pager
```

```bash
journalctl -u k3s -n 100 --no-pager
```

### 第 2 步：写镜像加速配置

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

确认内容：

```bash
cat /etc/rancher/k3s/registries.yaml
```

### 第 3 步：重启并清理失败 Pod

```bash
systemctl restart k3s
```

```bash
systemctl is-active k3s
```

预期输出 `active`。

等 20～30 秒，让 k3s 重新加载配置：

```bash
sleep 20
```

删除失败的 Pod，让它们按新配置重建：

```bash
kubectl delete pod -n kube-system --all
```

观察状态：

```bash
kubectl get pods -n kube-system -w
```

预期从 `ContainerCreating` 变成 `Running`。全部 `Running` 后按 `Ctrl+C`。

### 第 4 步：验收 server

```bash
kubectl get nodes -o wide
```

```bash
kubectl get pods -A -o wide
```

预期：

- `k8s-server` 是 `Ready`
- CoreDNS、local-path-provisioner、metrics-server、Traefik 都是 `Running`

如果还是 `ImagePullBackOff`：

```bash
kubectl describe pod -n kube-system <Pod名>
```

```bash
journalctl -u k3s -n 100 --no-pager
```

然后把 `registries.yaml` 的端点换成备用地址，再重启 k3s、删除 Pod：

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

### 第 5 步：加入 worker

只有第 4 步全部通过后再做。

worker-1：

- 写同样的 `registries.yaml`
- `config.yaml` 写 `node-ip: "172.25.254.11"`
- 从 server 取 token
- 执行 `sh -s - agent --server https://172.25.254.10:6443 --token "$TOKEN"`

worker-2 同理，`node-ip` 改成 `172.25.254.12`。

完整命令见第 4 节「什么时候加入 worker」。

### 当前不要做

- 不要在 worker 上执行 `sh -s - server`，那会变成另一个独立集群。
- 不要在 server 的 `kube-system` 还没全部 `Running` 时加入 worker。
- 不要把真实 token 写进文档、截图或 Git。

---

## 7. 三节点 Ready 之后先做什么

### 问题

镜像源和配置文件都弄好了，两个 worker 也加入了，三节点都是 `Ready`。下一步是不是直接装 Prometheus？

### 结论

**先不要装监控。先做冒烟测试。**

冒烟测试要确认三件事：

1. Pod 能正常调度到 worker。
2. Pod 网络能通。
3. Service 和 NodePort 能从集群外访问。

这三件事不通，后面装 Prometheus、Grafana、Loki 也会遇到网络问题，而且更难判断是监控配错了还是集群网络本身有问题。

### 第 1 步：确认系统 Pod 也干净

节点 `Ready` 不等于系统 Pod 都正常。先在 server 上跑：

```bash
kubectl get nodes -o wide
```

```bash
kubectl get pods -A -o wide
```

```bash
kubectl get pods -A --no-headers | grep -Ev 'Running|Completed' || true
```

预期：

- 三行节点，全部 `Ready`，`INTERNAL-IP` 分别是 `.10`、`.11`、`.12`。
- 最后一条命令没有输出。

如果最后一条有输出，先处理这些 Pod，不要继续：

```bash
kubectl describe pod -n <命名空间> <Pod名>
```

```bash
kubectl logs -n <命名空间> <Pod名> --tail=100
```

### 第 2 步：准备 smoke-test.yaml

仓库里的清单在 `infra/manifests/smoke-test.yaml`。

如果 server 上已经有仓库：

```bash
ls /root/learn_aiops_sre/infra/manifests/smoke-test.yaml
```

存在的话复制到 `/root`：

```bash
cp /root/learn_aiops_sre/infra/manifests/smoke-test.yaml /root/smoke-test.yaml
```

如果没有仓库，从 Windows 复制过去（PowerShell）：

```powershell
scp E:\learn_aiops_sre\infra\manifests\smoke-test.yaml root@172.25.254.10:/root/smoke-test.yaml
```

当前 server 使用 root，直接写 `root@172.25.254.10`。如果 Windows 连 root 被拒绝（sshd 的 `PermitRootLogin` 没开），就用有 SSH 权限的普通用户传输，再在 server 上 `sudo mv` 到 `/root`。

确认文件在 server 上：

```bash
ls -l /root/smoke-test.yaml
```

### 第 3 步：dry-run 和应用

```bash
kubectl apply --dry-run=client -f /root/smoke-test.yaml
```

预期：

```text
namespace/demo created (dry run)
deployment.apps/web created (dry run)
service/web created (dry run)
```

正式应用：

```bash
kubectl apply -f /root/smoke-test.yaml
```

### 第 4 步：验证 Pod、Service、NodePort

```bash
kubectl get pods -n demo -o wide
```

预期：两个 `web` Pod 都是 `Running`，尽量分别落在 `k8s-worker-1` 和 `k8s-worker-2`。

```bash
kubectl get svc -n demo
```

预期：`web` 是 `NodePort`，端口显示 `80:30080/TCP`。

```bash
kubectl get endpoints -n demo web
```

预期：`ENDPOINTS` 里有两个 Pod IP。

```bash
curl -I http://172.25.254.10:30080
```

预期：`HTTP/1.1 200 OK`。

也可以从 Windows 浏览器访问：

```text
http://172.25.254.10:30080
```

### 常见错误

**Pod 是 `ImagePullBackOff`**

说明 worker 拉不到 `nginx:1.27-alpine`。检查：

```bash
kubectl describe pod -n demo <Pod名>
```

到对应 worker 上检查：

```bash
cat /etc/rancher/k3s/registries.yaml
```

```bash
journalctl -u k3s-agent -n 100 --no-pager
```

确认两个 worker 都写了镜像加速配置。改完后重启 agent：

```bash
systemctl restart k3s-agent
```

**`curl` 连接失败**

先看 Service 和 Endpoints：

```bash
kubectl get svc -n demo
kubectl get endpoints -n demo web
```

再看节点有没有监听 30080：

```bash
ss -lntp | grep 30080
```

检查 ufw：

```bash
ufw status
```

实验环境应该关闭 ufw。如果 Endpoints 为空，说明 Service 的 selector 没匹配到 Pod。

**Pod 一直 `Pending`**

```bash
kubectl describe pod -n demo <Pod名>
```

重点看 `Events` 里的调度失败原因、资源不足、节点 taint。

**两个 Pod 都在同一台 worker**

不是冒烟失败。`smoke-test.yaml` 用的是 `ScheduleAnyway`，只做尽量打散。阶段 2 需要严格分布时，再改成 `DoNotSchedule` 或加 podAntiAffinity。

### 通过之后

下一步是资源基线：

1. 应用 `00-namespaces.yaml`、`01-limitrange.yaml`、`02-resourcequota.yaml`。
2. 验证 LimitRange 默认值和 ResourceQuota。
3. 收集验收输出，填写 `docs/02-lab/01-phase-0-1-acceptance.md`。
4. 三台 VM 打快照 `phase-1-k3s-ready`。

---

## 8. 冒烟测试和 smoke-test.yaml 是什么

### 问题

介绍一下这个冒烟测试和 `smoke-test.yaml`。

### 一句话结论

冒烟测试是部署完成后的**最小可用性检查**。它不证明业务逻辑正确，只回答一个问题：这套系统最基本的链路是不是通的。

`smoke-test.yaml` 用三个对象做这件事：

| 对象 | 作用 |
|---|---|
| `Namespace demo` | 给测试资源一个独立命名空间 |
| `Deployment web` | 跑 2 个 nginx Pod，验证调度、镜像拉取、容器启动 |
| `Service web` | 用 NodePort 30080 暴露，验证 Service、Endpoints、kube-proxy |

它验证的链路是：

```text
kubectl apply
  -> API Server
  -> Deployment 控制器
  -> ReplicaSet
  -> Scheduler 选节点
  -> kubelet
  -> containerd 拉镜像、起容器
  -> CNI 分配 Pod IP
  -> readinessProbe 通过
  -> Endpoints 加入 Pod IP
  -> kube-proxy 写 NodePort 规则
  -> curl 节点 IP:30080 返回 200
```

### 8.1 什么是「冒烟测试」

这个词来自硬件：新板子第一次通电，如果没冒烟，至少说明供电没炸。软件里的冒烟测试借用了这个意思：部署后先做一组很小的检查，确认系统没有“一上来就完全不可用”。

它和生产级测试的区别：

| | 冒烟测试 | 完整测试 |
|---|---|---|
| 目标 | 基本链路是否通 | 功能、性能、高可用、边界条件 |
| 规模 | 很小，几分钟 | 可能几小时 |
| 失败含义 | 先别继续，基础有问题 | 某个具体功能有问题 |
| 这次检查 | Pod 能否跑、Service 能否访问 | 业务逻辑、压测、故障注入 |

所以这一步通过，不代表集群“生产可用”，只代表可以继续做监控实验。

### 8.2 清单结构

`smoke-test.yaml` 是一个多文档 YAML，用 `---` 分隔三个 Kubernetes 对象：

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
...
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
...
```

`kubectl apply -f` 会按顺序处理这三个对象。

### 8.3 Namespace：为什么还要建 demo

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
```

Namespace 是资源隔离的边界。把测试服务放在 `demo` 里，后面做资源配额、LimitRange、清理实验资源时都方便。

仓库里的 `00-namespaces.yaml` 也会创建 `demo`。两边重复不冲突，`kubectl apply` 是幂等的：已存在就更新，不存在就创建。

### 8.4 Deployment：它到底管什么

Deployment 的职责是**维持期望状态**：你说要 2 个副本，它就让集群里一直有 2 个匹配的 Pod。Pod 挂了，ReplicaSet 会补一个。

关键字段：

```yaml
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
```

#### replicas: 2

用两个副本有三个目的：

1. 验证多 Pod 调度，不只是单 Pod 能跑。
2. 验证 Service 能把流量分到多个 Endpoints。
3. 观察两个副本会不会被分散到不同 worker。

#### selector 和 template labels

`selector.matchLabels.app: web` 必须和 `template.metadata.labels.app: web` 对得上。

如果两边不一致，API Server 会直接拒绝：

```text
Deployment.apps "web" is invalid: spec.template.metadata.labels:
Invalid value: ...: `selector` does not match template `labels`
```

这是新手很常见的一个错误：改了 Pod 标签，忘了改 selector。

#### nodeAffinity：尽量不调度到 server

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
```

意思是：**优先**选择没有 `control-plane` 标签的节点，也就是两个 worker。

注意这里是 `preferred`，不是 `required`：

- worker 资源够：两个 Pod 去 worker。
- worker 资源不够或有 taint：Pod 仍然可以落到 server，不会一直 Pending。

为什么不让业务 Pod 跑 server？因为 server 只有 6GB，后面还要放 Prometheus、Grafana、Loki 等监控组件。业务 Pod 尽量放 worker，资源更清楚。

#### topologySpreadConstraints：尽量打散

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: web
```

- `topologyKey: kubernetes.io/hostname`：按节点打散。
- `maxSkew: 1`：两个节点上的 Pod 数量差尽量不超过 1。
- `whenUnsatisfiable: ScheduleAnyway`：做不到也不阻塞调度，只是“尽量”。

所以两个 Pod 最好分别在 worker-1 和 worker-2。如果都在同一台，也不算冒烟失败。后面需要严格分布时，可以改成 `DoNotSchedule` 或加 podAntiAffinity。

#### 容器镜像和端口

```yaml
containers:
  - name: web
    image: nginx:1.27-alpine
    ports:
      - name: http
        containerPort: 80
```

- `nginx:1.27-alpine`：小、启动快、默认首页返回 200，适合做冒烟镜像。
- `containerPort: 80`：声明容器监听 80，并给它起名 `http`。
- `containerPort` 本身**不负责暴露端口**。真正让流量进来的是 Pod IP + Service + kube-proxy。命名端口的作用是让 Service 的 `targetPort` 和探针可以直接写 `http`。

#### resources：requests 和 limits

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

- `requests`：调度依据。Scheduler 会找至少有 50m CPU、64Mi 内存的节点。
- `limits`：运行上限。CPU 超了会被限流，内存超了可能被 OOMKilled。

`50m` 是 0.05 核，不是 50 核。`64Mi` 是 64 兆字节。

这两个值也是后面 LimitRange 和 ResourceQuota 实验的参照。没有 requests/limits 的 Pod，在配额命名空间里可能直接被拒绝。

#### readinessProbe：什么时候算“可以接流量”

```yaml
readinessProbe:
  httpGet:
    path: /
    port: http
  initialDelaySeconds: 2
  periodSeconds: 5
```

kubelet 会在容器启动 2 秒后，每 5 秒请求一次 `http://PodIP:80/`。

- 返回 2xx/3xx：Pod 变成 `Ready`，Endpoints 把它加入。
- 返回失败：Pod 还是 `Running`，但 `READY` 是 `0/1`，Service 不会把流量发给它。

这就是为什么有时候 `kubectl get pods` 显示 `Running`，但 `curl` 还是 503：Pod 没 Ready，Endpoints 是空的。

这里没有配 livenessProbe。对 nginx 这种简单服务，readiness 已经够用；liveness 配不好反而会导致无意义重启。

### 8.5 Service：NodePort 怎么把流量送进去

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
```

逐项解释：

| 字段 | 值 | 作用 |
|---|---|---|
| `type` | `NodePort` | 在每个节点上开一个端口，外部可以通过节点 IP 访问 |
| `selector` | `app: web` | 选中带 `app=web` 标签的 Pod |
| `port` | `80` | Service 自己的 ClusterIP 端口 |
| `targetPort` | `http` | 转发到容器名为 `http` 的端口，也就是 80 |
| `nodePort` | `30080` | 节点上固定的对外端口，范围默认 30000–32767 |

Service 不直接创建 Pod，它只是一个“虚拟入口”。真正干活的是：

1. Endpoints/EndpointSlice 控制器发现 Ready 的 Pod，把 Pod IP 写进 Endpoints。
2. 每个节点上的 kube-proxy 写 iptables/IPVS 规则。
3. 访问 `节点IP:30080` 时，规则把流量 DNAT 到某个 Pod IP:80。

k3s 把 kube-proxy 编进了 k3s 进程，所以 `kubectl get pods -n kube-system` 看不到 kube-proxy Pod，但规则是存在的。

NodePort 在**每台节点**上都可用，不只 server。也就是说下面三个地址理论上都能访问：

```text
http://172.25.254.10:30080
http://172.25.254.11:30080
http://172.25.254.12:30080
```

只要防火墙允许。

### 8.6 apply 之后发生了什么

```text
kubectl apply -f smoke-test.yaml
  │
  ├─ API Server 校验并保存 Namespace / Deployment / Service
  │
  ├─ Deployment 控制器创建 ReplicaSet
  │     └─ ReplicaSet 创建 2 个 Pod
  │
  ├─ Scheduler 选节点
  │     ├─ 看 nodeAffinity（尽量避开 control-plane）
  │     ├─ 看 topologySpread（尽量打散）
  │     └─ 看 requests（节点资源够不够）
  │
  ├─ kubelet 调用 containerd
  │     ├─ 拉 pause 沙箱镜像
  │     ├─ 拉 nginx:1.27-alpine
  │     └─ 创建容器
  │
  ├─ CNI（Flannel）给 Pod 分配 10.42.x.x
  │
  ├─ nginx 启动，readinessProbe GET / 返回 200
  │     └─ Pod 变成 Ready
  │
  ├─ Endpoints 控制器把 2 个 Pod IP 加入 Service
  │
  └─ kube-proxy 写入 NodePort 30080 的转发规则
        └─ curl 节点IP:30080 -> DNAT -> PodIP:80 -> 200
```

这条链路里任何一环坏了，表现都不一样。所以冒烟测试的价值不只是“最后 200”，而是能定位到哪一层出了问题。

### 8.7 结果怎么读

| 现象 | 大概率原因 | 先看什么 |
|---|---|---|
| Pod `Pending` | 没有节点能满足调度 | `kubectl describe pod -n demo <Pod>` 的 Events |
| `ImagePullBackOff` / `ErrImagePull` | 镜像拉不到、仓库配置不对 | `describe`，worker 的 `registries.yaml`，`journalctl -u k3s-agent` |
| `CrashLoopBackOff` | 容器启动后退出 | `kubectl logs -n demo <Pod>` |
| `Running` 但 `READY 0/1` | readinessProbe 失败 | `describe`，`kubectl logs`，进容器 `curl localhost` |
| Service 没有 Endpoints | selector 不匹配，或 Pod 没 Ready | `kubectl get pods -n demo --show-labels`，`kubectl get endpoints -n demo web` |
| `curl` 连接被拒绝 | NodePort 没监听、防火墙、IP 错 | `ss -lntp \| grep 30080`，`ufw status` |
| `curl` 返回 503 | Endpoints 为空或全部未 Ready | `kubectl get endpoints -n demo web` |
| `curl` 返回 404 | 路径不对 | 试 `curl -I http://...:30080/` |

一个容易混淆的点：

- `Running` 只表示容器进程在跑。
- `Ready` 才表示 readinessProbe 通过，可以接流量。
- `kubectl get pods` 的 `READY` 列是 `就绪容器数/总容器数`。

### 8.8 这个测试覆盖了什么，没覆盖什么

覆盖：

- API Server 能接收资源
- Deployment/ReplicaSet 控制器工作
- Scheduler 能调度
- kubelet 能启动 Pod
- containerd 能拉镜像
- Flannel/CNI 能给 Pod 分配 IP
- readinessProbe 能工作
- Service/Endpoints 能生成
- kube-proxy/NodePort 能把外部流量转进 Pod

没覆盖：

- **DNS**：nginx 不需要解析域名，所以这个测试没验证 CoreDNS。
- **Ingress/Traefik**：走的是 NodePort，不是 Ingress。
- **持久化存储**：没有 PVC。
- **NetworkPolicy**：没有策略。
- **ResourceQuota/LimitRange**：下一阶段单独验证。
- **HPA/指标**：metrics-server 还没参与。
- **跨节点 Pod 直连**：NodePort 可能转到任意节点上的 Pod，但不是专门测 Pod-to-Pod。
- **性能和稳定性**：没有压测、没有故障注入。

所以它叫“冒烟”，不叫“验收全部功能”。

### 8.9 为什么这样设计

- **2 个副本**：能看出调度和 Service 负载均衡，不是单 Pod 自嗨。
- **nginx alpine**：镜像小、启动快、默认页稳定返回 200。
- **soft spread**：两台 worker 的实验环境，硬性打散容易因为一台资源不足而 Pending。
- **preferred 避开 server**：业务尽量在 worker，但不把调度卡死。
- **requests/limits**：提前暴露资源问题，也为后面的配额实验做铺垫。
- **readinessProbe**：确保 Service 只把流量发给真正准备好的 Pod。
- **NodePort**：不需要云 LoadBalancer，也不需要先装 Ingress，最适合本地实验。

### 8.10 实操命令

```bash
# 1. 客户端 dry-run，先看 YAML 有没有明显语法问题
kubectl apply --dry-run=client -f /root/smoke-test.yaml

# 2. 正式应用
kubectl apply -f /root/smoke-test.yaml

# 3. 看 Pod 落在哪台节点
kubectl get pods -n demo -o wide

# 4. 看 Service 的 NodePort
kubectl get svc -n demo

# 5. 看 Endpoints 是否有两个 Pod IP
kubectl get endpoints -n demo web

# 6. 从集群外访问
curl -I http://172.25.254.10:30080
```

如果第 6 步返回 `HTTP/1.1 200 OK`，说明从 API Server 到 NodePort 的主链路已经通了。

---

## 9. 冒烟测试通过后做什么

### 问题

`kubectl apply -f` 之后，Windows 主机能访问任意节点 IP:30080，能看到 nginx 欢迎页，没什么问题。下一步做什么？

### 结论

阶段 0–1 的**集群底座和网络主链路已经通了**。接下来不要再重复冒烟测试，进入资源基线：

1. 创建 `aiops`、`demo`、`monitoring` 三个命名空间。
2. 在 `demo` 和 `aiops` 设置 LimitRange 默认资源。
3. 在 `demo` 设置 ResourceQuota。
4. 验证默认值和配额。
5. 收集阶段 0–1 验收输出，填验收文档。
6. 三台 VM 打快照 `phase-1-k3s-ready`。

先不要装 Prometheus。资源基线没做完就上监控，后面容易出现 Pod 被 OOM、配额不够、默认值不生效的问题。

### 9.1 三个资源分别管什么

| 资源 | 作用范围 | 作用 |
|---|---|---|
| Namespace | 集群级 | 隔离资源，方便按命名空间清理和配额 |
| LimitRange | 单个命名空间 | 给没写 resources 的容器注入默认 requests/limits；限制单容器最大值 |
| ResourceQuota | 单个命名空间 | 限制整个命名空间的总 requests/limits/Pod 数量 |

关键区别：

- **LimitRange 管“单个容器”**：默认给多少、最大能要多少。
- **ResourceQuota 管“整个命名空间”**：所有 Pod 加起来不能超过多少。
- LimitRange 只在**创建 Pod 时**注入默认值，不会修改已经存在的 Pod。
- ResourceQuota 会把已有资源计入 `Used`，但不会因为超配额去驱逐已有 Pod；它主要拦截新建资源。

### 9.2 应用三个清单

以下假设三个文件已经放到 server 的 `/root/manifests/`。如果你在 server 上有仓库，把路径换成 `infra/manifests/` 即可。

```bash
kubectl apply -f /root/manifests/00-namespaces.yaml
```

预期：

```text
namespace/aiops created
namespace/demo configured
namespace/monitoring created
```

`demo` 可能显示 `unchanged` 或 `configured`，因为冒烟测试已经创建过它。

```bash
kubectl apply -f /root/manifests/01-limitrange.yaml
```

预期：

```text
limitrange/default-limits created
limitrange/default-limits created
```

两个 `default-limits` 分别在 `aiops` 和 `demo`。

```bash
kubectl apply -f /root/manifests/02-resourcequota.yaml
```

预期：

```text
resourcequota/demo-quota created
```

### 9.3 验证命名空间

```bash
kubectl get ns
```

预期能看到：

```text
aiops
demo
monitoring
```

### 9.4 验证 LimitRange

```bash
kubectl describe limitrange -n demo
```

预期看到：

```text
Default Request:
  cpu:     50m
  memory:  64Mi
Default:
  cpu:     500m
  memory:  256Mi
Max:
  cpu:     1
  memory:  1Gi
```

`aiops` 里也有同样的限制：

```bash
kubectl describe limitrange -n aiops
```

### 9.5 验证 ResourceQuota

```bash
kubectl describe quota -n demo
```

预期看到 `Hard` 值：

```text
requests.cpu:     2
requests.memory:  2Gi
limits.cpu:       4
limits.memory:    4Gi
pods:             20
```

`Used` 里会显示当前 `demo` 的用量。冒烟测试的两个 `web` Pod 会计入：

- requests：约 `100m` CPU、`128Mi` 内存
- limits：约 `400m` CPU、`256Mi` 内存
- Pod 数：`2`

具体数值以实际输出为准。

### 9.6 验证 LimitRange 默认值真的生效

创建一个**不写 resources** 的临时 Pod：

```bash
kubectl run quota-check -n demo --image=nginx:1.27-alpine --restart=Never
```

预期：

```text
pod/quota-check created
```

查看它的 resources：

```bash
kubectl get pod quota-check -n demo -o jsonpath='{.spec.containers[0].resources}'; echo
```

预期包含：

```json
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

字段顺序可能不同，只要数值对得上就说明 LimitRange 生效了。

再看一次配额，`Used` 里会多一个 Pod：

```bash
kubectl describe quota -n demo
```

删除临时 Pod：

```bash
kubectl delete pod quota-check -n demo
```

### 9.7 收集阶段 0–1 验收输出

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

在两个 worker 上分别执行：

```bash
free -h
df -h
systemctl status k3s-agent --no-pager
```

把这些输出贴回来，就可以把 `docs/02-lab/01-phase-0-1-acceptance.md` 里的 `<待填写>` 替换成真实结果。

验收重点：

- 三节点全部 `Ready`
- 系统 Pod 全部 `Running`
- `demo` 两个 `web` Pod 在 worker 上
- `curl` 返回 `200 OK`
- LimitRange 和 ResourceQuota 数值正确
- server 可用内存大于 1 GB，worker 大于 800 MB

### 9.8 打快照

验收输出确认无误后，在 VMware 里给三台虚拟机分别打快照，命名：

```text
phase-1-k3s-ready
```

快照前先关机或暂停，避免磁盘状态不一致。

### 常见问题

**`kubectl run` 报 `exceeded quota`**

说明临时 Pod 加上现有 `web` 的用量超过了 `demo-quota`。先看：

```bash
kubectl describe quota -n demo
```

按当前配置，默认的 `50m/64Mi` 请求应该还能放进去；如果放不进，说明 `web` 的副本数或资源被改过。

**`kubectl describe limitrange` 看不到默认值**

确认 Pod 和 LimitRange 在同一个命名空间。LimitRange 是命名空间级的，`demo` 里的规则不会作用到 `default` 命名空间。

**Pod 创建成功但没有注入 resources**

LimitRange 只对创建时没有写 resources 的容器生效。如果容器自己写了 `resources`，就用容器自己的值，不会被默认值覆盖。

**`kubectl describe quota` 里 `Used` 是 0**

配额刚创建、还没有统计到，或者 Pod 在其他命名空间。等几秒再看，并确认命名空间是 `demo`。

---

## 10. 更正：server 当前使用 root

### 更正

之前示例里偶尔出现 `aiops@...` 的写法。当前 server 实际使用 **root** 登录，后续 server 上的命令直接用 root，不需要 `sudo`。

### 影响

- `scp` 目标改为：

```powershell
scp -r E:\learn_aiops_sre\infra\manifests root@172.25.254.10:/root/
```

- server 上执行 `kubectl`、`systemctl`、`tee`、`cat` 等命令不需要加 `sudo`。
- 如果 Windows 连 root 被拒绝，说明 sshd 没允许 root 登录；这时用有 SSH 权限的普通用户传文件，再在 server 上 `sudo mv` 到 `/root`。这不影响后续集群操作。
- 文档里的 `/root/...` 路径按当前 root 用户写；如果以后改用普通用户，把路径换成该用户的家目录。

### 验证

```bash
whoami
```

预期：

```text
root
```

---

## 11. 三个资源 YAML 逐行解释

### 问题

`00-namespaces.yaml`、`01-limitrange.yaml`、`02-resourcequota.yaml` 每个文件分别是什么意思？

### 先看三个文件的关系

| 文件 | 创建的对象 | 作用范围 | 解决的问题 |
|---|---|---|---|
| `00-namespaces.yaml` | 3 个 Namespace | 集群级 | 划出 `aiops`、`demo`、`monitoring` 三个隔离区 |
| `01-limitrange.yaml` | 2 个 LimitRange | 单个命名空间 | 给容器注入默认 requests/limits，并限制单容器最大值 |
| `02-resourcequota.yaml` | 1 个 ResourceQuota | 单个命名空间 | 限制 `demo` 里所有 Pod 加起来的总量 |

推荐应用顺序：

```text
Namespace -> LimitRange -> ResourceQuota
```

不是 Kubernetes 强制要求这个顺序，而是逻辑上更安全：先有命名空间，再有默认资源，最后有总量限制。如果先建 Quota 且没有 LimitRange，创建不带 resources 的 Pod 会被 Quota 拒绝。

---

### 11.1 `00-namespaces.yaml`

完整内容：

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: aiops
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
```

#### `apiVersion: v1`

Namespace 属于 Kubernetes 核心 API 组，所以是 `v1`，不是 `apps/v1`。

#### `kind: Namespace`

声明这是一个命名空间对象。

Namespace 是**集群级资源**，它本身不属于任何命名空间，所以没有 `metadata.namespace` 字段。

#### `metadata.name`

命名空间的名字。这里分别是：

- `aiops`：后面放 AIOps 相关服务。
- `demo`：放冒烟测试和演示服务。
- `monitoring`：后面放 Prometheus、Grafana、Loki 等监控组件。

命名空间名字必须符合 DNS label 规则：小写字母、数字、`-`，不能有大写、下划线，不能以 `-` 开头或结尾。

#### `---`

YAML 多文档分隔符。一个文件里可以写多个 Kubernetes 对象，`kubectl apply -f` 会依次处理。

#### 为什么 `demo` 在冒烟测试里也创建过

`smoke-test.yaml` 里也有一个 `Namespace demo`。重复不冲突，因为 `kubectl apply` 是幂等的：

- 不存在：创建。
- 已存在且内容一样：`unchanged`。
- 已存在但内容不同：更新。

这样每个清单都可以单独使用，不依赖别的文件先跑。

#### 验证

```bash
kubectl get ns
```

预期看到 `aiops`、`demo`、`monitoring`，状态都是 `Active`。

---

### 11.2 `01-limitrange.yaml`

文件里有两个几乎一样的 LimitRange，分别给 `aiops` 和 `demo`。这里拿 `demo` 那段解释：

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: demo
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 50m
        memory: 64Mi
      default:
        cpu: 500m
        memory: 256Mi
      max:
        cpu: "1"
        memory: 1Gi
```

#### `apiVersion: v1` 和 `kind: LimitRange`

LimitRange 也属于核心 API 组，所以是 `v1`。

#### `metadata.name: default-limits`

这个 LimitRange 的名字。`aiops` 和 `demo` 里都叫 `default-limits`，这是允许的，因为 LimitRange 是**命名空间级**资源，不同命名空间可以有同名对象。

#### `metadata.namespace: demo`

这条规则只作用于 `demo` 命名空间。`demo` 里的 LimitRange 不会影响 `aiops`、`monitoring` 或 `default`。

#### `spec.limits`

LimitRange 的规则列表。这里只有一条：

```yaml
- type: Container
```

`type: Container` 表示规则作用于**单个容器**。LimitRange 还支持 `type: Pod`，用来限制整个 Pod 的总量；这里不用。

#### `defaultRequest`

```yaml
defaultRequest:
  cpu: 50m
  memory: 64Mi
```

如果容器**没有写 requests**，就自动注入：

- CPU request：`50m`，也就是 0.05 核。
- 内存 request：`64Mi`，也就是 64 MiB。

requests 是调度依据：Scheduler 会找至少有这么多资源的节点。

#### `default`

```yaml
default:
  cpu: 500m
  memory: 256Mi
```

如果容器**没有写 limits**，就自动注入：

- CPU limit：`500m`，也就是 0.5 核。
- 内存 limit：`256Mi`。

limits 是运行上限：CPU 超了会被限流，内存超了可能被 OOMKilled。

#### `max`

```yaml
max:
  cpu: "1"
  memory: 1Gi
```

单个容器的 request/limit 不能超过：

- CPU：1 核。
- 内存：1 GiB。

比如你写 `cpu: 2` 或 `memory: 2Gi`，Pod 会被 API Server 拒绝。

`cpu: "1"` 加引号是因为 Kubernetes 的 quantity 既可以是数字也可以是字符串；加引号更明确，避免 YAML 把它当纯数字。

#### 默认值和显式值谁优先

- 容器自己写了 requests/limits：用容器自己的值。
- 容器没写：LimitRange 注入默认值。
- 容器写了但超过 `max`：拒绝。

LimitRange 只在**创建 Pod 时**生效，不会回头修改已经存在的 Pod。改大或改小 LimitRange，已有的 Pod 还是原来的资源，除非重建。

#### 为什么 `aiops` 也有，`monitoring` 没有

`aiops` 和 `demo` 是实验里会随手创建 Pod 的命名空间，给默认值可以避免“没写 resources 被配额拒绝”。

`monitoring` 后面会放 Prometheus、Grafana、Loki，这些组件会有明确的 resources 配置，暂时不加默认值，避免默认限制和组件自身配置互相干扰。

#### 验证

```bash
kubectl describe limitrange -n demo
```

预期看到：

```text
Default Request:
  cpu:     50m
  memory:  64Mi
Default:
  cpu:     500m
  memory:  256Mi
Max:
  cpu:     1
  memory:  1Gi
```

---

### 11.3 `02-resourcequota.yaml`

完整内容：

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: demo-quota
  namespace: demo
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"
```

#### `kind: ResourceQuota`

ResourceQuota 用来限制**一个命名空间内所有 Pod 的总量**，不是单个 Pod，也不是单个容器。

#### `metadata.namespace: demo`

这条配额只作用于 `demo`。`aiops` 和 `monitoring` 不受影响。

#### `spec.hard`

`hard` 是一个“上限表”，每一项都是命名空间内所有 Pod 的合计值。

| 字段 | 含义 |
|---|---|
| `requests.cpu: "2"` | 所有 Pod 的 CPU requests 加起来不能超过 2 核 |
| `requests.memory: 2Gi` | 所有 Pod 的内存 requests 加起来不能超过 2 GiB |
| `limits.cpu: "4"` | 所有 Pod 的 CPU limits 加起来不能超过 4 核 |
| `limits.memory: 4Gi` | 所有 Pod 的内存 limits 加起来不能超过 4 GiB |
| `pods: "20"` | 命名空间里最多 20 个 Pod |

注意：

- `requests` 影响调度和配额；`limits` 影响运行上限和配额。
- 配额统计的是**所有 Pod 的合计**，不是单个 Pod。
- 已经存在的 Pod 会计入 `Used`，但配额不会因为超了去驱逐它们；它主要拦截新建 Pod。
- 新建 Pod 时如果会超过任何一项，API Server 返回 `Forbidden`，Pod 创建失败。

#### 为什么是 2 / 2Gi / 4 / 4Gi / 20

这是根据实验环境定的：

- 两个 worker 合计 4 vCPU、4 GiB 内存。
- `requests` 设 2 核 / 2Gi，留出余量给系统 Pod 和突发。
- `limits` 设 4 核 / 4Gi，允许一定程度的超卖和突发，但不会无限膨胀。
- `pods: 20` 防止实验时不小心创建太多副本。

这不是生产参数，是 16GB 宿主机上三台小 VM 的实验参数。

#### 和 LimitRange 的区别

| | LimitRange | ResourceQuota |
|---|---|---|
| 管什么 | 单个容器 | 整个命名空间 |
| 典型作用 | 默认 requests/limits、单容器上限 | 总 requests/limits、Pod 数量 |
| 超了会怎样 | 单个 Pod 被拒绝 | 新建 Pod 被拒绝 |
| 是否修改已有 Pod | 不会 | 不会 |

两者配合：

1. LimitRange 给没写 resources 的容器补默认值。
2. ResourceQuota 再检查这些值加起来有没有超总量。

如果只有 ResourceQuota 没有 LimitRange，创建不带 resources 的 Pod 时，Quota 会因为“不知道 requests/limits 是多少”而拒绝。LimitRange 正好补上这个缺口。

#### 用冒烟测试算一遍

`web` 有 2 个副本，每个：

```text
requests: 50m CPU, 64Mi 内存
limits:   200m CPU, 128Mi 内存
```

两个副本合计：

```text
requests: 100m CPU, 128Mi 内存
limits:   400m CPU, 256Mi 内存
pods:     2
```

再创建一个默认资源的 `quota-check` Pod：

```text
requests: 50m CPU, 64Mi 内存
limits:   500m CPU, 256Mi 内存
pods:     1
```

总计：

```text
requests: 150m CPU, 192Mi 内存
limits:   900m CPU, 512Mi 内存
pods:     3
```

都低于 `demo-quota` 的 2 核 / 2Gi / 4 核 / 4Gi / 20，所以能创建成功。

如果继续创建两个 requests 各 1 核的 Pod：

- 第一个之后：requests 约 1.15 核，还能放下。
- 第二个之后：约 2.15 核，超过 2 核，第二个会被拒绝。

这就是 Quota 的“总量拦截”。

#### 验证

```bash
kubectl describe quota -n demo
```

预期看到 `Hard` 和 `Used`：

```text
Resource         Used   Hard
--------         ----   ----
limits.cpu       400m   4
limits.memory    256Mi  4Gi
pods             2      20
requests.cpu     100m   2
requests.memory  128Mi  2Gi
```

具体数值以实际输出为准；创建临时 Pod 后 `Used` 会增加。

---

### 11.4 三个文件怎么配合

```text
00-namespaces.yaml
  └─ 划出 aiops / demo / monitoring 三个隔离区

01-limitrange.yaml
  └─ 在 aiops、demo 里规定：
       没写 request -> 默认 50m / 64Mi
       没写 limit   -> 默认 500m / 256Mi
       单容器最大   -> 1 核 / 1Gi

02-resourcequota.yaml
  └─ 在 demo 里规定：
       所有 Pod 的 requests 合计 <= 2 核 / 2Gi
       所有 Pod 的 limits 合计   <= 4 核 / 4Gi
       Pod 数量 <= 20
```

一次 Pod 创建要经过两道关：

```text
你提交 Pod
  │
  ├─ LimitRange 准入：
  │    没写 resources？补默认值
  │    超过单容器 max？拒绝
  │
  └─ ResourceQuota 准入：
       加上这个 Pod 后超过 namespace 总量？拒绝
       没超过？允许创建
```

---

### 11.5 验证命令汇总

```bash
# 命名空间
kubectl get ns

# LimitRange 默认值和最大值
kubectl describe limitrange -n demo
kubectl describe limitrange -n aiops

# ResourceQuota 的 Hard 和 Used
kubectl describe quota -n demo

# 创建一个不带 resources 的临时 Pod，验证默认值注入
kubectl run quota-check -n demo --image=nginx:1.27-alpine --restart=Never

# 看注入后的 resources
kubectl get pod quota-check -n demo -o jsonpath='{.spec.containers[0].resources}'; echo

# 删除临时 Pod
kubectl delete pod quota-check -n demo
```

预期临时 Pod 的 resources 包含：

```json
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

字段顺序可能不同，数值对得上就说明 LimitRange 生效。

---

## 12. 资源清单解释完之后下一步做什么

### 问题

三个 YAML 已经理解了，下一步做什么？

### 结论

**把三个清单真正 apply 上去，然后验证。**

理解 YAML 只是知道它会创建什么；apply 之后集群里才会有 Namespace、LimitRange、ResourceQuota。如果你已经 apply 过，就直接跳到验证。

### 第 1 步：确认文件在 server 上

```bash
ls -l /root/manifests/
```

预期看到：

```text
00-namespaces.yaml
01-limitrange.yaml
02-resourcequota.yaml
```

如果文件不在，先按上一条的 `scp` 命令从 Windows 复制。

### 第 2 步：应用三个清单

```bash
kubectl apply -f /root/manifests/00-namespaces.yaml
```

预期：

```text
namespace/aiops created
namespace/demo configured
namespace/monitoring created
```

```bash
kubectl apply -f /root/manifests/01-limitrange.yaml
```

预期：

```text
limitrange/default-limits created
limitrange/default-limits created
```

```bash
kubectl apply -f /root/manifests/02-resourcequota.yaml
```

预期：

```text
resourcequota/demo-quota created
```

### 第 3 步：验证资源对象

```bash
kubectl get ns
```

预期看到 `aiops`、`demo`、`monitoring`。

```bash
kubectl describe limitrange -n demo
```

预期看到默认请求 `50m/64Mi`、默认限制 `500m/256Mi`、单容器最大 `1/1Gi`。

```bash
kubectl describe quota -n demo
```

预期看到 `Hard`：

```text
requests.cpu     2
requests.memory  2Gi
limits.cpu       4
limits.memory    4Gi
pods             20
```

### 第 4 步：验证默认值真的注入

```bash
kubectl run quota-check -n demo --image=nginx:1.27-alpine --restart=Never
```

```bash
kubectl get pod quota-check -n demo -o jsonpath='{.spec.containers[0].resources}'; echo
```

预期包含：

```json
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

删除临时 Pod：

```bash
kubectl delete pod quota-check -n demo
```

### 第 5 步：通过后

下一步是阶段 0–1 验收：

1. 收集 server 和两个 worker 的输出。
2. 填 `docs/02-lab/01-phase-0-1-acceptance.md`。
3. 三台 VM 打快照 `phase-1-k3s-ready`。

验收命令见第 9.7 节。

---

## 后续记录约定

- 每次有新的问题，在本文末尾追加一节，标题格式：`## N. 日期 + 问题摘要`。
- 每节至少保留：问题、结论、原因/原理、可复现命令、验证方式。
- 涉及 token、密码、私钥时只写「在 server 上取 token」，不记录真实值。
- 如果问题跨多个阶段，优先放在本文，方便按时间回看；需要展开成专题时，再在 `docs/01-principles/` 或 `docs/02-lab/` 下新建文档，并在本文留链接。
