#!/usr/bin/env bash
# Pre-flight checks for a disposable VPS before running run-public-install.sh.
# Checks the provider-side requirements that qemu cannot model: TUN,
# WireGuard kernel support, OS, free ports, resources and outbound access.
#
# Usage:
#   VPS_IP=203.0.113.10 VPS_SSH_KEY=~/.ssh/id_ed25519 \
#   [VPS_SSH_PORT=22] [VPS_ROOT_USER=root] tests/e2e/vps-preflight.sh
#
# shellcheck disable=SC2016,SC2029  # remote commands: variables expand on the VPS
set -euo pipefail

: "${VPS_IP:?VPS_IP is required}"
: "${VPS_SSH_KEY:?VPS_SSH_KEY is required}"
VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
VPS_ROOT_USER="${VPS_ROOT_USER:-root}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"

TARGET="${VPS_ROOT_USER}@${VPS_IP}"
ssh_opts=(-p "${VPS_SSH_PORT}" -i "${VPS_SSH_KEY}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=10)

fail() { echo "[FAIL] $*" >&2; exit 1; }
run() { ssh "${ssh_opts[@]}" "${TARGET}" "$@"; }

if ! run 'echo ok' >/dev/null 2>&1; then
    fail "SSH to ${TARGET}:${VPS_SSH_PORT} failed"
fi
echo "[ok] SSH reachable"

os_id="$(run '. /etc/os-release; echo "$ID $VERSION_ID"')"
[[ "${os_id}" == debian* || "${os_id}" == ubuntu* ]] || fail "unsupported OS: ${os_id}"
echo "[ok] OS: ${os_id}"

arch="$(run 'uname -m')"
[[ "${arch}" == x86_64 ]] || fail "unsupported architecture: ${arch}; amd64 is required"
echo "[ok] architecture: amd64"

memory_mib="$(run 'awk '\''/^MemTotal:/ { print int($2 / 1024); exit }'\'' /proc/meminfo')"
[[ "${memory_mib}" =~ ^[0-9]+$ && "${memory_mib}" -ge 1024 ]] \
    || fail "at least 1024 MiB physical RAM is required: ${memory_mib:-unknown} MiB"
echo "[ok] physical memory: ${memory_mib} MiB"

run 'awk '\''BEGIN { print "[info] existing swap (diagnostic only; installation must not change it):" } { print }'\'' /proc/swaps'

run 'test -e /dev/net/tun' || fail "/dev/net/tun is missing (enable TUN in the provider panel)"
echo "[ok] /dev/net/tun present"

if run 'modinfo wireguard >/dev/null 2>&1 || ip link add wg-preflight type wireguard 2>/dev/null'; then
    run 'ip link delete wg-preflight 2>/dev/null || true' >/dev/null || true
    echo "[ok] WireGuard kernel support"
else
    fail "WireGuard is not available in the kernel (modinfo and ip link both failed)"
fi

virt="$(run 'systemd-detect-virt 2>/dev/null || true')"
echo "[info] virtualization: ${virt:-unknown} (lxc/openvz would skip UFW enable)"

used="$(run "ss -lntup 2>/dev/null | grep -E '\:(${E2E_SSH_PORT}|${E2E_WG_PORT})\b' || true")"
if [[ -n "${used}" ]]; then
    echo "[warn] ports ${E2E_SSH_PORT}/${E2E_WG_PORT} are already in use on the VPS:"
    echo "${used}"
else
    echo "[ok] ports ${E2E_SSH_PORT}/tcp and ${E2E_WG_PORT}/udp are free on the VPS"
fi

run 'df -h / | tail -1'
run 'free -m | awk "/Mem:/{printf \"[info] memory: %d MB total, %d MB free\n\", \$2, \$7}"'

echo "[check] outbound connectivity (apt, GitHub, PyPI, Docker, ghcr.io):"
run '
  for url in https://github.com https://pypi.org https://download.docker.com https://ghcr.io; do
    if curl -fsS -o /dev/null --max-time 10 "$url"; then
      echo "  [ok] $url"
    else
      echo "  [warn] $url unreachable"
    fi
  done
'

echo "[ok] preflight finished - the VPS is ready for run-public-install.sh"
