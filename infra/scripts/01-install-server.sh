#!/usr/bin/env bash
#
# Install a single-node k3s server for the AIOps lab.
#
# Usage:
#   sudo ./01-install-server.sh <node-ip> <hostname>
#
# Example:
#   sudo ./01-install-server.sh 172.25.254.10 k8s-server
#
# Run 00-baseline.sh first. The script writes /etc/rancher/k3s/config.yaml,
# installs the stable channel, and waits until the node reports Ready.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./01-install-server.sh <node-ip> <hostname>

  node-ip    IPv4 address of this server on the NAT network
  hostname   k8s-server (must match the hostname set by 00-baseline.sh)

The script is safe to re-run: if k3s is already active it restarts the
service to apply the current config instead of reinstalling.
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

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"

NODE_IP=$1
HOSTNAME_ARG=$2

validate_ipv4 "$NODE_IP" || die "invalid node IP: $NODE_IP"
[[ $HOSTNAME_ARG =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
  || die "invalid hostname: $HOSTNAME_ARG"

command -v curl >/dev/null 2>&1 || die "curl not found; run 00-baseline.sh first"
ip -4 addr show | grep -q "inet ${NODE_IP}/" \
  || die "IP $NODE_IP is not configured on this host; run 00-baseline.sh first"

if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  echo "warning: swap is enabled; run 00-baseline.sh first" >&2
fi

echo "==> Writing /etc/rancher/k3s/config.yaml"
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
write-kubeconfig-mode: "0644"
node-ip: "${NODE_IP}"
tls-san:
  - "${NODE_IP}"
  - "${HOSTNAME_ARG}"
EOF

if systemctl is-active --quiet k3s 2>/dev/null; then
  echo "==> k3s is already active; restarting to apply config"
  systemctl restart k3s
else
  echo "==> Installing k3s stable channel"
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - server
fi

echo "==> Waiting for the node to become Ready (max 180s)"
ready=0
for _ in $(seq 1 60); do
  if k3s kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" { found=1 } END { exit !found }'; then
    ready=1
    break
  fi
  sleep 3
done

if [[ $ready -ne 1 ]]; then
  echo "error: k3s server did not become Ready" >&2
  systemctl status k3s --no-pager || true
  journalctl -u k3s -n 50 --no-pager || true
  exit 1
fi

echo "==> Server is Ready"
k3s kubectl get nodes -o wide

cat <<EOF

Node token: /var/lib/rancher/k3s/server/node-token
Next, on each worker:

  sudo ./02-join-agent.sh https://${NODE_IP}:6443 "\$(sudo cat /var/lib/rancher/k3s/server/node-token)" <worker-ip>
EOF
