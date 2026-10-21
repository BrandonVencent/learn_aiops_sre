#!/usr/bin/env bash
#
# Join a worker to the k3s server.
#
# Usage:
#   sudo ./02-join-agent.sh <server-url> <token|-> <node-ip>
#
# Examples:
#   sudo ./02-join-agent.sh https://172.25.254.10:6443 - 172.25.254.11
#   sudo ./02-join-agent.sh https://172.25.254.10:6443 "$TOKEN" 172.25.254.12
#
# Using "-" reads the token from the terminal without echoing it, so it
# does not land in shell history.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./02-join-agent.sh <server-url> <token|-> <node-ip>

  server-url  https://<server-ip>:6443
  token       node token from /var/lib/rancher/k3s/server/node-token,
              or "-" to paste it without echo
  node-ip     IPv4 address of this worker on the NAT network

Run 00-baseline.sh first. Verify the join on the server with:
  kubectl get nodes -o wide
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

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"

SERVER_URL=$1
TOKEN=$2
NODE_IP=$3

[[ $SERVER_URL =~ ^https://[^/]+$ ]] \
  || die "server-url must look like https://<ip>:6443"

if [[ $TOKEN == "-" ]]; then
  [[ -t 0 ]] || die "token '-' requires an interactive terminal"
  read -r -s -p "Paste node token: " TOKEN
  echo
fi

[[ -n $TOKEN ]] || die "token is empty"
[[ $TOKEN =~ ^[A-Za-z0-9:_-]+$ ]] || die "token contains unexpected characters"

validate_ipv4 "$NODE_IP" || die "invalid node IP: $NODE_IP"
ip -4 addr show | grep -q "inet ${NODE_IP}/" \
  || die "IP $NODE_IP is not configured on this host; run 00-baseline.sh first"

command -v curl >/dev/null 2>&1 || die "curl not found; run 00-baseline.sh first"

echo "==> Checking connectivity to ${SERVER_URL}"
curl -k -fsS --max-time 5 "${SERVER_URL}/cacerts" >/dev/null \
  || die "cannot reach ${SERVER_URL}; check the server URL, IP and firewall"

echo "==> Writing /etc/rancher/k3s/config.yaml"
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
node-ip: "${NODE_IP}"
EOF

if systemctl is-active --quiet k3s-agent 2>/dev/null; then
  echo "==> k3s-agent is already active; skipping install"
else
  echo "==> Installing k3s agent"
  curl -sfL https://get.k3s.io | \
    K3S_URL="$SERVER_URL" \
    K3S_TOKEN="$TOKEN" \
    INSTALL_K3S_CHANNEL=stable \
    sh -s - agent
fi

echo "==> Waiting for k3s-agent (max 60s)"
active=0
for _ in $(seq 1 20); do
  if systemctl is-active --quiet k3s-agent 2>/dev/null; then
    active=1
    break
  fi
  sleep 3
done

if [[ $active -ne 1 ]]; then
  echo "error: k3s-agent is not active" >&2
  systemctl status k3s-agent --no-pager || true
  journalctl -u k3s-agent -n 50 --no-pager || true
  exit 1
fi

echo "==> Agent is active"
echo "Verify on the server: kubectl get nodes -o wide"
