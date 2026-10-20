# K8s 实验集群搭建（阶段 0–1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在三台 VMware Ubuntu 虚拟机上搭好 k3s 三节点集群，完成系统基线、节点加入和冒烟测试。

**Architecture:** 一台 6GB server 跑控制面，两台 2GB worker 跑业务；所有节点使用 VMware NAT 静态 IP；k3s 使用 stable channel，固定 `node-ip` 和 `tls-san`；仓库保存可复用的基线脚本、安装脚本和冒烟清单。

**Tech Stack:** VMware Workstation、Ubuntu Server 24.04 LTS、k3s stable、kubectl、PowerShell、Bash。

**Spec:** `docs/02-lab/00-lab-design.md`

## Global Constraints

- 宿主机：Windows，16 GB 内存，14 核 20 线程，仓库所在磁盘至少 100 GB 空闲。
- 虚拟机：`k8s-server` 4 vCPU / 6 GB / 60 GB；`k8s-worker-1`、`k8s-worker-2` 各 2 vCPU / 2 GB / 20 GB。
- 系统：Ubuntu Server 24.04 LTS，安装 OpenSSH，用户 `aiops` 具备 sudo。
- 网络：VMware `VMnet8` NAT；静态 IP 使用 `192.168.N.10/11/12`，网关 `192.168.N.2`；`N` 由宿主机实际网段决定。
- 集群：k3s stable channel，不固定小版本；server 和 agent 都必须设置 `node-ip`。
- 安全：节点 token、kubeconfig 不提交到仓库；脚本里的 token 只通过参数或环境变量传入。
- 所有 YAML 用 `kubectl apply -f`，不使用 `kubectl edit`。
- 每个任务结束必须有可复现的验证命令，并单独提交。

## Review Focus

1. **网卡名或 NAT 子网写错**：`netplan apply` 后节点失联，SSH 断开。Task 2 用 `ip -br link` 和 `ping` 验证。
2. **静态 IP 落在 DHCP 池或子网外**：节点能启动但无法上网或互相访问。Task 1 读取 `VMnet8` 网段，Task 2 用网关 ping 验证。
3. **k3s server 因 swap、防火墙或 `node-ip` 未就绪**：服务反复重启。Task 3 用 `systemctl is-active` 和 `kubectl get nodes` 验证。
4. **worker 的 URL 或 token 错误**：节点永远不加入。Task 4 用三节点 `Ready` 和 Pod 分布验证。
5. **内存超卖**：后续装监控时 worker 被 OOM。Task 6 用 LimitRange 和实际 `free -h` 验证余量。

---

### Task 1: 仓库骨架与宿主机预检

**Files:**
- Create: `infra/vm/check-host.ps1`
- Create: `infra/vm/README.md`
- Create: `.gitignore`

**Interfaces:**
- Consumes: 无
- Produces: `check-host.ps1` 输出四行：`RAM_GB`、`FREE_DISK_GB`、`VMNET8_IP`、`VMNET8_GATEWAY`。后续任务用这些值确定 `N`。

- [ ] **Step 1: 写宿主机检查脚本**

`infra/vm/check-host.ps1` 需要做三件事：

1. 用 `Get-CimInstance Win32_ComputerSystem` 算物理内存 GB。
2. 用 `Get-PSDrive` 查仓库所在盘剩余空间 GB。
3. 用 `Get-NetIPAddress -AddressFamily IPv4` 找 `InterfaceAlias` 包含 `VMnet8` 的地址，并输出网关（同网段 `.2`）。

输出格式固定为 `KEY=VALUE`，方便人工读取和后续脚本解析。

- [ ] **Step 2: 运行检查脚本**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File infra/vm/check-host.ps1
```

Expected:

```text
RAM_GB=16
FREE_DISK_GB=<大于 100 的数字>
VMNET8_IP=192.168.N.1
VMNET8_GATEWAY=192.168.N.2
```

如果 `FREE_DISK_GB` 小于 100，停止后续任务，先清理磁盘。

- [ ] **Step 3: 写 VMware 创建说明**

`infra/vm/README.md` 记录：

- 三台虚拟机的名称、vCPU、内存、磁盘、网络模式。
- Ubuntu Server 24.04 ISO 的下载地址和安装选项（OpenSSH、用户 `aiops`）。
- `VMnet8` 网段的查看方法（`ipconfig` 或检查脚本）。
- 静态 IP 分配表：`.10` server、`.11` worker-1、`.12` worker-2。
- 安装完成后移除 ISO、打第一个快照 `phase-0-os-installed`。

- [ ] **Step 4: 写 `.gitignore`**

至少包含：

```text
*.token
*kubeconfig*
.kube/
.env
.venv/
__pycache__/
*.log
```

- [ ] **Step 5: 提交**

```bash
git add .gitignore infra/vm/check-host.ps1 infra/vm/README.md
git commit -m "chore: add host preflight check and VM setup notes"
```

---

### Task 2: 三台 Ubuntu 虚拟机与系统基线

**Files:**
- Create: `infra/scripts/00-baseline.sh`
- Modify: `infra/vm/README.md`

**Interfaces:**
- Consumes: Task 1 输出的 `VMNET8_GATEWAY` 和网段。
- Produces: 三台机器具备固定 hostname、静态 IP、`/etc/hosts` 互解、swap 关闭、内核模块和 sysctl 就绪。

- [ ] **Step 1: 在 VMware 中创建三台虚拟机**

按 `infra/vm/README.md` 的表格创建，安装 Ubuntu Server 24.04。安装时勾选 OpenSSH Server，创建用户 `aiops`。worker 只有 2GB 内存，如果安装器报内存不足，临时调到 3GB，装完再改回 2GB。

- [ ] **Step 2: 写基线脚本**

`infra/scripts/00-baseline.sh` 的调用方式：

```bash
sudo ./00-baseline.sh <hostname> <ip-cidr> <gateway> <interface> <dns>
```

示例：

```bash
sudo ./00-baseline.sh k8s-server 192.168.190.10/24 192.168.190.2 ens33 223.5.5.5
```

脚本必须做到：

1. `hostnamectl set-hostname` 设置主机名。
2. 写入 `/etc/hosts`，包含三台机器的 IP 和主机名。
3. 写入 `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`，内容为 `network: {config: disabled}`，防止 cloud-init 覆盖网络配置。
4. 生成 `/etc/netplan/99-static.yaml`：`dhcp4: false`、静态地址、默认路由、DNS。
5. 执行 `netplan apply`。
6. `swapoff -a`，并注释 `/etc/fstab` 里的 swap 行。
7. 加载 `overlay`、`br_netfilter`，写入 `/etc/modules-load.d/k8s.conf`。
8. 写入 `/etc/sysctl.d/k8s.conf`：`net.bridge.bridge-nf-call-iptables=1`、`net.ipv4.ip_forward=1`，执行 `sysctl --system`。
9. 设置时区 `Asia/Shanghai`，开启 NTP。
10. `apt update`，安装 `curl`、`ca-certificates`。
11. 关闭 ufw（仅实验环境），并说明生产应放行 6443/tcp、8472/udp、10250/tcp。

脚本要幂等：重复执行不报错、不重复追加配置。

- [ ] **Step 3: 语法检查**

Run:

```bash
bash -n infra/scripts/00-baseline.sh
```

Expected: 无输出，退出码 0。

- [ ] **Step 4: 在三台机器上执行**

从 VMware 控制台执行，避免改 IP 时 SSH 断开。

```bash
# k8s-server
sudo ./00-baseline.sh k8s-server 192.168.N.10/24 192.168.N.2 ens33 223.5.5.5

# k8s-worker-1
sudo ./00-baseline.sh k8s-worker-1 192.168.N.11/24 192.168.N.2 ens33 223.5.5.5

# k8s-worker-2
sudo ./00-baseline.sh k8s-worker-2 192.168.N.12/24 192.168.N.2 ens33 223.5.5.5
```

`ens33` 以 `ip -br link` 的实际输出为准。

- [ ] **Step 5: 验证基线**

在每台机器上运行：

```bash
hostname
ip -4 addr show
ping -c 2 192.168.N.2
ping -c 2 192.168.N.10
ping -c 2 192.168.N.11
ping -c 2 192.168.N.12
getent hosts k8s-server k8s-worker-1 k8s-worker-2
swapon --show
timedatectl
```

Expected:

- `hostname` 与分配表一致。
- 网关和三个节点 IP 都能 ping 通。
- `getent hosts` 能解析三个主机名。
- `swapon --show` 无输出。
- `timedatectl` 显示 NTP 已同步。

- [ ] **Step 6: 提交**

```bash
git add infra/scripts/00-baseline.sh infra/vm/README.md
git commit -m "feat: add Ubuntu baseline script for k3s nodes"
```

---

### Task 3: 安装 k3s server

**Files:**
- Create: `infra/scripts/01-install-server.sh`

**Interfaces:**
- Consumes: Task 2 完成基线的 `k8s-server`。
- Produces: `k3s` systemd 服务、`/etc/rancher/k3s/k3s.yaml`、`/var/lib/rancher/k3s/server/node-token`。

- [ ] **Step 1: 写 server 安装脚本**

调用方式：

```bash
sudo ./01-install-server.sh <node-ip> <hostname>
```

示例：

```bash
sudo ./01-install-server.sh 192.168.190.10 k8s-server
```

脚本必须做到：

1. 写 `/etc/rancher/k3s/config.yaml`：

```yaml
write-kubeconfig-mode: "0644"
node-ip: "<node-ip>"
tls-san:
  - "<node-ip>"
  - "<hostname>"
```

2. 用官方脚本安装 stable：

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - server
```

3. 等待 `kubectl get nodes` 能看到 server 且状态为 `Ready`，最多等 180 秒。
4. 输出 node token 的路径，不把 token 写进仓库。

- [ ] **Step 2: 语法检查**

Run:

```bash
bash -n infra/scripts/01-install-server.sh
```

Expected: 无输出，退出码 0。

- [ ] **Step 3: 在 server 上执行**

```bash
sudo ./01-install-server.sh 192.168.N.10 k8s-server
```

- [ ] **Step 4: 验证 server**

Run:

```bash
systemctl is-active k3s
sudo kubectl get nodes -o wide
sudo kubectl get pods -A
sudo cat /var/lib/rancher/k3s/server/node-token
```

Expected:

- `systemctl is-active k3s` 输出 `active`。
- `kubectl get nodes` 显示 `k8s-server` 为 `Ready`。
- `kubectl get pods -A` 里 CoreDNS、Traefik、local-path、metrics-server 均为 `Running`。
- token 文件存在且非空。

- [ ] **Step 5: 提交**

```bash
git add infra/scripts/01-install-server.sh
git commit -m "feat: add k3s server install script"
```

---

### Task 4: 加入两个 worker

**Files:**
- Create: `infra/scripts/02-join-agent.sh`

**Interfaces:**
- Consumes: Task 3 的 server URL `https://192.168.N.10:6443` 和 node token。
- Produces: 两个 k3s agent 节点，状态 `Ready`。

- [ ] **Step 1: 写 agent 加入脚本**

调用方式：

```bash
sudo ./02-join-agent.sh <server-url> <token> <node-ip>
```

示例：

```bash
sudo ./02-join-agent.sh https://192.168.190.10:6443 "<token>" 192.168.190.11
```

脚本必须做到：

1. 写 `/etc/rancher/k3s/config.yaml`，包含 `node-ip`。
2. 用官方脚本安装 agent：

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL="<server-url>" \
  K3S_TOKEN="<token>" \
  INSTALL_K3S_CHANNEL=stable \
  sh -s - agent
```

3. 检查 `systemctl is-active k3s-agent`，失败时输出 `journalctl -u k3s-agent` 的最后 50 行。

- [ ] **Step 2: 语法检查**

Run:

```bash
bash -n infra/scripts/02-join-agent.sh
```

Expected: 无输出，退出码 0。

- [ ] **Step 3: 在两个 worker 上执行**

先从 server 取 token：

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

然后分别在 worker-1、worker-2 执行脚本，`node-ip` 换成各自的地址。

- [ ] **Step 4: 验证三节点**

在 server 上运行：

```bash
sudo kubectl get nodes -o wide
sudo kubectl get pods -A -o wide
```

Expected:

- 三行节点，全部 `Ready`，`INTERNAL-IP` 分别是 `.10`、`.11`、`.12`。
- 系统 Pod 分布在多个节点，不是全部挤在 server。

- [ ] **Step 5: 提交**

```bash
git add infra/scripts/02-join-agent.sh
git commit -m "feat: add k3s agent join script"
```

---

### Task 5: kubeconfig 与集群冒烟测试

**Files:**
- Create: `infra/scripts/03-kubeconfig.sh`
- Create: `infra/manifests/smoke-test.yaml`

**Interfaces:**
- Consumes: Task 4 的三节点集群。
- Produces: 可直接使用的 `~/.kube/config`，以及一个可访问的 `demo/web` 服务。

- [ ] **Step 1: 写 kubeconfig 脚本**

调用方式：

```bash
./03-kubeconfig.sh <server-ip>
```

脚本必须：

1. 创建 `~/.kube`。
2. 复制 `/etc/rancher/k3s/k3s.yaml` 到 `~/.kube/config`。
3. 把 `server: https://127.0.0.1:6443` 替换为 `https://<server-ip>:6443`。
4. 设置文件权限 `600`，属主为当前用户。
5. 输出在 Windows 上使用的说明（把文件复制到 `%USERPROFILE%\.kube\config`，并安装 kubectl）。

- [ ] **Step 2: 写冒烟清单**

`infra/manifests/smoke-test.yaml` 包含：

- Namespace `demo`。
- Deployment `web`，2 副本，镜像 `nginx:1.27-alpine`，容器端口 80。
- Service `web`，类型 `NodePort`，端口 80，nodePort 30080。
- 资源 requests/limits：`50m/64Mi`、`200m/128Mi`。

- [ ] **Step 3: 客户端 dry-run**

Run:

```bash
kubectl apply --dry-run=client -f infra/manifests/smoke-test.yaml
```

Expected: 输出 `namespace/demo created (dry run)`、`deployment.apps/web created (dry run)`、`service/web created (dry run)`。

- [ ] **Step 4: 应用并验证**

Run:

```bash
kubectl apply -f infra/manifests/smoke-test.yaml
kubectl get pods -n demo -o wide
kubectl get svc -n demo
curl -I http://192.168.N.10:30080
```

Expected:

- 两个 Pod 都是 `Running`，且尽量落在不同 worker。
- Service 显示 `30080:30080/TCP`。
- `curl` 返回 `HTTP/1.1 200 OK`。

- [ ] **Step 5: 提交**

```bash
git add infra/scripts/03-kubeconfig.sh infra/manifests/smoke-test.yaml
git commit -m "feat: add kubeconfig helper and smoke test manifest"
```

---

### Task 6: 命名空间与资源基线

**Files:**
- Create: `infra/manifests/00-namespaces.yaml`
- Create: `infra/manifests/01-limitrange.yaml`
- Create: `infra/manifests/02-resourcequota.yaml`

**Interfaces:**
- Consumes: Task 4 的集群。
- Produces: `aiops`、`demo`、`monitoring` 三个命名空间；`demo` 的默认资源限制和配额。

- [ ] **Step 1: 写命名空间清单**

`00-namespaces.yaml` 创建：

```text
aiops
demo
monitoring
```

- [ ] **Step 2: 写 LimitRange**

`01-limitrange.yaml` 在 `demo` 和 `aiops` 两个命名空间设置：

- 默认 request：`cpu: 50m`、`memory: 64Mi`
- 默认 limit：`cpu: 500m`、`memory: 256Mi`
- 单容器最大：`cpu: 1`、`memory: 1Gi`

- [ ] **Step 3: 写 ResourceQuota**

`02-resourcequota.yaml` 只在 `demo` 设置：

```text
requests.cpu: 2
requests.memory: 2Gi
limits.cpu: 4
limits.memory: 4Gi
pods: 20
```

- [ ] **Step 4: 应用并验证**

Run:

```bash
kubectl apply -f infra/manifests/00-namespaces.yaml
kubectl apply -f infra/manifests/01-limitrange.yaml
kubectl apply -f infra/manifests/02-resourcequota.yaml
kubectl describe limitrange -n demo
kubectl describe quota -n demo
```

Expected: LimitRange 和 ResourceQuota 都显示设定的值。

- [ ] **Step 5: 验证默认值真的生效**

创建一个不带 resources 的临时 Pod：

```bash
kubectl run quota-check -n demo --image=nginx:1.27-alpine --restart=Never
kubectl get pod quota-check -n demo -o jsonpath='{.spec.containers[0].resources}'
kubectl delete pod quota-check -n demo
```

Expected: 输出包含 `requests` 和 `limits`，值与 LimitRange 一致。

- [ ] **Step 6: 提交**

```bash
git add infra/manifests/00-namespaces.yaml infra/manifests/01-limitrange.yaml infra/manifests/02-resourcequota.yaml
git commit -m "feat: add namespaces and resource guardrails"
```

---

### Task 7: 验收记录与快照

**Files:**
- Create: `docs/02-lab/01-phase-0-1-acceptance.md`

**Interfaces:**
- Consumes: Task 1–6 的全部产出。
- Produces: 一份可复查的验收记录，以及 VMware 快照 `phase-1-k3s-ready`。

- [ ] **Step 1: 收集验收输出**

在 server 上运行并保存输出：

```bash
kubectl version
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc -A
free -h
df -h
systemctl status k3s --no-pager
```

在两个 worker 上运行：

```bash
free -h
df -h
systemctl status k3s-agent --no-pager
```

- [ ] **Step 2: 写验收文档**

`docs/02-lab/01-phase-0-1-acceptance.md` 包含：

- 实际使用的 `VMnet8` 网段和三台 IP。
- k3s 版本。
- 三节点 `Ready` 的输出。
- `curl` 冒烟测试结果。
- 每个节点的内存和磁盘余量；server 可用内存应大于 1 GB，worker 应大于 800 MB，否则阶段 2 会 OOM。
- 与计划的偏差（如果有）。
- 下一步（阶段 2：指标链路）的前置条件。

- [ ] **Step 3: 打快照**

在 VMware 中给三台虚拟机分别打快照，命名 `phase-1-k3s-ready`。快照前先关机或暂停，避免数据不一致。

- [ ] **Step 4: 提交**

```bash
git add docs/02-lab/01-phase-0-1-acceptance.md
git commit -m "docs: record phase 0-1 acceptance results"
```

---

## 完成标准

- `kubectl get nodes` 三节点全部 `Ready`。
- `demo/web` 两个 Pod 运行在不同节点，NodePort 能返回 200。
- `demo` 命名空间的 LimitRange 和 ResourceQuota 生效。
- 三台虚拟机都有 `phase-1-k3s-ready` 快照。
- 验收文档记录了真实输出，而不是计划里的预期值。
