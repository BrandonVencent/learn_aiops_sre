#!/usr/bin/env bash
#
# Baseline an Ubuntu Server VM for the k3s lab.
#
# Usage:
#   sudo ./00-baseline.sh <hostname> <ip-cidr> <gateway> <interface> [dns]
#
# Example:
#   sudo ./00-baseline.sh k8s-server 172.25.254.10/24 172.25.254.2 ens33 223.5.5.5
#
# Run this from the VMware console: changing the IP will drop the SSH session.
# The /etc/hosts block assumes the lab addresses .10, .11 and .12.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./00-baseline.sh <hostname> <ip-cidr> <gateway> <interface> [dns]

  hostname    k8s-server | k8s-worker-1 | k8s-worker-2
  ip-cidr     static address with prefix, e.g. 172.25.254.10/24
  gateway     VMware NAT gateway, e.g. 172.25.254.2
  interface   from `ip -br link`, e.g. ens33
  dns         optional, default 223.5.5.5

The script is idempotent. It disables cloud-init network config, writes
/etc/netplan/99-static.yaml, turns off swap, loads kernel modules, sets
sysctl values, and disables ufw (lab only).
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

validate_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local IFS=.
  local -a octets=($ip)
  local o
  for o in "${octets[@]}"; do
    if (( o < 0 || o > 255 )); then
      return 1
    fi
  done
  return 0
}

if [[ $# -lt 4 || $# -gt 5 ]]; then
  usage
  exit 2
fi

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"

HOSTNAME_ARG=$1
IP_CIDR=$2
GATEWAY=$3
IFACE=$4
DNS=${5:-223.5.5.5}

[[ $HOSTNAME_ARG =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
  || die "invalid hostname: $HOSTNAME_ARG"

BASE_IP=${IP_CIDR%/*}
PREFIX_LEN=${IP_CIDR#*/}
[[ $BASE_IP != "$IP_CIDR" ]] || die "ip-cidr must include a prefix, e.g. 172.25.254.10/24"
validate_ipv4 "$BASE_IP" || die "invalid IPv4 address: $BASE_IP"
[[ $PREFIX_LEN =~ ^[0-9]{1,2}$ ]] || die "invalid prefix length: $PREFIX_LEN"
if (( PREFIX_LEN < 1 || PREFIX_LEN > 32 )); then
  die "prefix length must be between 1 and 32"
fi

validate_ipv4 "$GATEWAY" || die "invalid gateway: $GATEWAY"
validate_ipv4 "$DNS" || die "invalid dns: $DNS"

ip link show "$IFACE" >/dev/null 2>&1 \
  || die "interface '$IFACE' not found; run: ip -br link"

SUBNET=${BASE_IP%.*}

echo "==> Installing base packages (network still on DHCP)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates

echo "==> Setting hostname: $HOSTNAME_ARG"
hostnamectl set-hostname "$HOSTNAME_ARG"

echo "==> Updating /etc/hosts"
if grep -q '# BEGIN aiops-lab' /etc/hosts; then
  sed -i '/# BEGIN aiops-lab/,/# END aiops-lab/d' /etc/hosts
fi
cat >> /etc/hosts <<EOF
# BEGIN aiops-lab
${SUBNET}.10 k8s-server
${SUBNET}.11 k8s-worker-1
${SUBNET}.12 k8s-worker-2
# END aiops-lab
EOF

echo "==> Disabling swap"
swapoff -a || true
if [[ -f /etc/fstab ]]; then
  sed -i -E 's/^([^#[:space:]].*[[:space:]]swap[[:space:]].*)$/# \1/' /etc/fstab
fi

echo "==> Loading kernel modules"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "==> Writing sysctl settings"
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "==> Setting timezone and NTP"
timedatectl set-timezone Asia/Shanghai
timedatectl set-ntp true || echo "warning: could not enable NTP; check systemd-timesyncd" >&2

echo "==> Disabling ufw (lab only)"
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable >/dev/null || true
fi

echo "==> Writing static network config"
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
fi

# Ubuntu Server ships a cloud-init netplan file that would keep DHCP on.
for f in /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config.yaml; do
  if [[ -f "$f" ]]; then
    mv -f "$f" "${f}.disabled"
    echo "    disabled conflicting netplan file: $f"
  fi
done

cat > /etc/netplan/99-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${IP_CIDR}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS}
EOF
chmod 600 /etc/netplan/99-static.yaml

netplan generate
netplan apply

cat <<EOF

Baseline applied:
  hostname : ${HOSTNAME_ARG}
  interface: ${IFACE}
  address  : ${IP_CIDR}
  gateway  : ${GATEWAY}
  dns      : ${DNS}
  hosts    : ${SUBNET}.10 / .11 / .12

If you are connected over SSH, reconnect at the new address.
Production note: instead of disabling the firewall, allow 6443/tcp,
8472/udp and 10250/tcp.
EOF
