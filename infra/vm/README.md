# VMware 虚拟机准备

## 1. 先跑宿主机检查

在仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File infra/vm/check-host.ps1
```

输出示例（本机实测）：

```text
RAM_GB=15.8
FREE_DISK_GB=118.1
VMNET8_IP=172.25.254.1
VMNET8_GATEWAY=172.25.254.2
VMNET8_PREFIX=24
```

本机 `VMnet8` 网段是 `172.25.254.0/24`，网关 `172.25.254.2`。后面统一使用这个网段；换机器时以脚本输出为准。

如果输出 `VMNET8_IP=NOT_FOUND`，先在 VMware 的「虚拟网络编辑器」里确认 `VMnet8` 存在并启用 NAT。

## 2. 虚拟机清单

| 主机名 | 角色 | vCPU | 内存 | 磁盘 | 网络 |
|---|---|---|---|---|---|
| `k8s-server` | k3s server | 4 | 6 GB | 60 GB | NAT (VMnet8) |
| `k8s-worker-1` | k3s agent | 2 | 2 GB | 20 GB | NAT (VMnet8) |
| `k8s-worker-2` | k3s agent | 2 | 2 GB | 20 GB | NAT (VMnet8) |

磁盘用**精简置备**（thin provision）。宿主机至少留 100 GB 空闲。

## 3. 安装 Ubuntu Server 24.04 LTS

ISO 下载页：<https://releases.ubuntu.com/24.04/>

每台虚拟机：

1. 新建虚拟机，选择「稍后安装操作系统」，客户机系统选 Ubuntu 64-bit。
2. 按上表分配 vCPU、内存、磁盘。
3. 网络适配器选 **NAT**。
4. 挂载 ISO，启动安装。
5. 安装过程中：
   - 语言选 English 或中文均可。
   - 网络先保持 DHCP，装完再用脚本改静态 IP。
   - 勾选 **Install OpenSSH server**。
   - 创建用户 `aiops`，记住密码。
   - 不安装额外的 snap 服务。
6. 安装完成后关机，移除 ISO，再启动。

## 4. 静态 IP 分配

假设检查脚本输出的网关是 `172.25.254.2`：

| 主机名 | IP | 网关 | DNS |
|---|---|---|---|
| `k8s-server` | `172.25.254.10/24` | `172.25.254.2` | `223.5.5.5` |
| `k8s-worker-1` | `172.25.254.11/24` | `172.25.254.2` | `223.5.5.5` |
| `k8s-worker-2` | `172.25.254.12/24` | `172.25.254.2` | `223.5.5.5` |

`.10`～`.12` 通常不在 VMware NAT 的 DHCP 池里，避免和自动分配冲突。

## 5. 网卡名

在虚拟机里执行：

```bash
ip -br link
```

常见名字是 `ens33`、`ens160`、`ens192`。baseline 脚本的第四个参数就是它。

## 6. 执行 baseline

把 `infra/scripts/00-baseline.sh` 复制到虚拟机，或在虚拟机里用 `scp` 拉取。然后：

```bash
sudo ./00-baseline.sh k8s-server 172.25.254.10/24 172.25.254.2 ens33 223.5.5.5
```

改 IP 时 SSH 会断开，建议从 VMware 控制台执行。改完后用新 IP 重新连接。

三台机器都执行完，按计划 Task 2 的验证步骤检查：

```bash
hostname
ip -4 addr show
ping -c 2 172.25.254.2
ping -c 2 172.25.254.10
ping -c 2 172.25.254.11
ping -c 2 172.25.254.12
getent hosts k8s-server k8s-worker-1 k8s-worker-2
swapon --show
timedatectl
```

## 7. 快照

系统基线验证通过后，在 VMware 里给三台虚拟机打快照，命名：

```text
phase-0-os-installed
```

k3s 安装并验证通过后，再打一个：

```text
phase-1-k3s-ready
```

快照前先关机，避免磁盘和内存状态不一致。

## 8. 常见问题

- **改完 IP 后连不上**：确认虚拟机和宿主机在同一个 `VMnet8` 网段，网关是 `.2`，并且没有启用宿主机的第三方防火墙拦截。
- **虚拟机不能上网**：检查 VMware NAT 服务是否运行，DNS 是否能解析。
- **worker 安装 Ubuntu 时内存不足**：临时把内存调到 3 GB，装完再改回 2 GB。
- **`netplan apply` 报错**：用 `sudo netplan try` 查看具体行号和缩进问题，YAML 对空格敏感。
