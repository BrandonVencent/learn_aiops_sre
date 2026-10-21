#!/usr/bin/env bash
#
# Install a usable kubeconfig for the invoking user.
#
# Usage:
#   sudo ./03-kubeconfig.sh <server-ip>
#
# Example:
#   sudo ./03-kubeconfig.sh 172.25.254.10
#
# Reads /etc/rancher/k3s/k3s.yaml, points it at the server's NAT address,
# and writes it to the invoking user's ~/.kube/config with mode 600.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./03-kubeconfig.sh <server-ip>

  server-ip  the k3s server's NAT address, e.g. 172.25.254.10

Run this on the server after 01-install-server.sh. Then:

  kubectl get nodes -o wide

To use it from Windows, copy the file to %USERPROFILE%\.kube\config.
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

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"
validate_ipv4 "$1" || die "invalid server IP: $1"

SERVER_IP=$1
SOURCE=/etc/rancher/k3s/k3s.yaml

[[ -f $SOURCE ]] || die "$SOURCE not found; run 01-install-server.sh first"

TARGET_USER=${SUDO_USER:-$USER}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n $TARGET_HOME && -d $TARGET_HOME ]] || die "cannot resolve home for user: $TARGET_USER"
TARGET_GROUP=$(id -gn "$TARGET_USER")

TARGET_DIR="$TARGET_HOME/.kube"
TARGET_FILE="$TARGET_DIR/config"

echo "==> Writing $TARGET_FILE for $TARGET_USER"
mkdir -p "$TARGET_DIR"
cp "$SOURCE" "$TARGET_FILE"
sed -i "s|https://127.0.0.1:6443|https://${SERVER_IP}:6443|g" "$TARGET_FILE"
chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_DIR"
chmod 700 "$TARGET_DIR"
chmod 600 "$TARGET_FILE"

echo "==> kubeconfig ready"
echo "Test as $TARGET_USER: kubectl get nodes -o wide"
echo
echo "Windows: copy $TARGET_FILE to %USERPROFILE%\\.kube\\config"
echo "  scp ${TARGET_USER}@${SERVER_IP}:${TARGET_FILE} \$env:USERPROFILE\\.kube\\config"
