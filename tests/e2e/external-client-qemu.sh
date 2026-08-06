#!/usr/bin/env bash
# E2E: a real external WireGuard client (fresh qemu/KVM VM) connecting to an
# already-deployed real VPS over the public internet. This is the final piece
# the in-guest test cannot cover: the actual public endpoint, the provider UDP
# port, a real internet handshake, DNS via the VPS AdGuard and the .internal
# HTTPS endpoints served by the VPS Caddy with the private root CA.
#
# The client peer is registered directly through the wg-easy container
# (the wg-easy CLI is broken in some image builds, so we append the peer to
# wg0.conf + apply it at runtime, and remove it afterwards).
#
# Usage:
#   tests/e2e/external-client-qemu.sh
#
# Env:
#   VPS_HOST         real VPS public IP (required)
#   VPS_SSH_PORT     hardened SSH port on the VPS (default 2222)
#   VPS_SSH_USER     SSH user with passwordless sudo (default sysadmin)
#   VPS_SSH_KEY      SSH private key for the VPS (default $HOME/.ssh/id_ed25519)
#   VPS_WG_PORT      WireGuard UDP port on the VPS (default 51820)
#   QEMU_IMAGE       cloud image for the client VM (default Ubuntu 24.04 noble)
#   QEMU_SSH_PORT    host tcp port -> client VM:22 (default 2224)
#   FULL_TUNNEL      client AllowedIPs 0.0.0.0/0 (default 1)
#   KEEP_PEER        keep the test peer on the VPS after the run (default 0)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

: "${VPS_HOST:?VPS_HOST is required}"
VPS_SSH_PORT="${VPS_SSH_PORT:-2222}"
VPS_SSH_USER="${VPS_SSH_USER:-sysadmin}"
VPS_SSH_KEY="${VPS_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
VPS_WG_PORT="${VPS_WG_PORT:-51820}"
DEFAULT_IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
QEMU_IMAGE="${QEMU_IMAGE:-${DEFAULT_IMAGE}}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2224}"
FULL_TUNNEL="${FULL_TUNNEL:-1}"
KEEP_PEER="${KEEP_PEER:-0}"
CLIENT_IP="10.8.0.5"

for tool in qemu-system-x86_64 qemu-img genisoimage curl ssh-keygen openssl ssh tar; do
    command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done

SSH_CMD=(ssh -p "${VPS_SSH_PORT}" -i "${VPS_SSH_KEY}"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10 -o BatchMode=yes "${VPS_SSH_USER}@${VPS_HOST}")

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-extclient.XXXXXX")"
QEMU_PID=""
CLIENT_PUB=""
cleanup() {
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
        sleep 2
    fi
    if [[ "${KEEP_PEER}" != "1" && -n "${CLIENT_PUB}" ]]; then
        echo "[cleanup] removing the test peer from the VPS"
        # drop the peer from the running interface
        "${SSH_CMD[@]}" "sudo docker exec wg-easy wg set wg0 peer ${CLIENT_PUB} remove" \
            >/dev/null 2>&1 || true
        # drop the matching [Peer] paragraph from wg0.conf (keeps other peers
        # and the interface block intact; wg-easy rewrites this file from its DB)
        "${SSH_CMD[@]}" 'sudo python3 -' >/dev/null 2>&1 <<PYEOF || true
import re
p = "/opt/zero-trust-vps/volumes/wg-easy/wg0.conf"
data = open(p).read()
parts = re.split(r"(?=^\[Peer\]\n)", data, flags=re.M)
data = "".join(b for b in parts if not b.startswith("[Peer]\n") or "PublicKey = ${CLIENT_PUB}" not in b)
open(p, "w").write(data)
PYEOF
        # verify both runtime and file no longer reference the test peer
        local runtime_gone=true file_gone=true
        if "${SSH_CMD[@]}" "sudo docker exec wg-easy wg show wg0 | grep -q '${CLIENT_PUB}'" >/dev/null 2>&1; then
            runtime_gone=false
        fi
        if "${SSH_CMD[@]}" "sudo grep -q '${CLIENT_PUB}' /opt/zero-trust-vps/volumes/wg-easy/wg0.conf" >/dev/null 2>&1; then
            file_gone=false
        fi
        if [[ "${runtime_gone}" == "true" && "${file_gone}" == "true" ]]; then
            echo "[cleanup] test peer fully removed (runtime + wg0.conf)"
        else
            echo "[cleanup][WARN] the test peer is still present on the VPS (runtime_gone=${runtime_gone}, file_gone=${file_gone})" >&2
        fi
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "[E2E] external client -> real VPS ${VPS_HOST}:${VPS_WG_PORT}"

# --- register the client peer on the VPS --------------------------------------
echo "[E2E] checking the VPS is reachable and wg-easy is running"
"${SSH_CMD[@]}" 'sudo docker ps --format "{{.Names}} {{.Status}}" | grep -q "^wg-easy " && echo VPS_OK' \
    >/dev/null 2>&1 || fail "VPS ${VPS_HOST} is not reachable or wg-easy is not running"

echo "[E2E] generating a client keypair and registering the peer"
CLIENT_PRIV="$("${SSH_CMD[@]}" 'sudo docker exec wg-easy wg genkey' 2>/dev/null | grep -v setlocale | tr -d '\r')"
[[ -n "${CLIENT_PRIV}" ]] || fail "could not generate a client key inside the wg-easy container"
CLIENT_PUB="$(printf '%s' "${CLIENT_PRIV}" | "${SSH_CMD[@]}" 'sudo docker exec -i wg-easy wg pubkey' 2>/dev/null | grep -v setlocale | tr -d '\r')"
SERVER_PUB="$("${SSH_CMD[@]}" 'sudo docker exec wg-easy wg show wg0 public-key' 2>/dev/null | grep -v setlocale | tr -d '\r')"
[[ -n "${CLIENT_PUB}" && -n "${SERVER_PUB}" ]] || fail "could not derive WireGuard keys"

"${SSH_CMD[@]}" "sudo bash -c 'grep -qF \"${CLIENT_PUB}\" /opt/zero-trust-vps/volumes/wg-easy/wg0.conf || printf \"\\n[Peer]\\nPublicKey = ${CLIENT_PUB}\\nAllowedIPs = ${CLIENT_IP}/32\\n\\n\" >> /opt/zero-trust-vps/volumes/wg-easy/wg0.conf' &&
    sudo docker exec wg-easy wg set wg0 peer ${CLIENT_PUB} allowed-ips ${CLIENT_IP}/32" >/dev/null 2>&1
pass "peer ${CLIENT_IP} registered on the VPS"

echo "[E2E] fetching the private root CA from the VPS"
ROOT_CA="${TMP_DIR}/root.crt"
"${SSH_CMD[@]}" 'sudo cat /opt/zero-trust-vps-installer/repo/fetched_certs/localhost/root.crt' \
    2>/dev/null | grep -v setlocale > "${ROOT_CA}"
chmod 600 "${ROOT_CA}"
grep -q 'BEGIN CERTIFICATE' "${ROOT_CA}" || fail "root CA could not be fetched"

# --- client configuration (mirrors the wg-easy default template) ---------------
if [[ "${FULL_TUNNEL}" == "1" ]]; then
    CLIENT_ALLOWED="0.0.0.0/0, ::/0"
    MODE_LABEL="full tunnel"
else
    CLIENT_ALLOWED="10.8.0.0/24, 10.66.0.2/32, 10.66.0.3/32"
    MODE_LABEL="split tunnel"
fi
cat > "${TMP_DIR}/client.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/32
DNS = 10.66.0.2

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${VPS_HOST}:${VPS_WG_PORT}
AllowedIPs = ${CLIENT_ALLOWED}
PersistentKeepalive = 25
EOF
echo "[E2E] client mode: ${MODE_LABEL}, endpoint ${VPS_HOST}:${VPS_WG_PORT}"

# --- boot the client VM ---------------------------------------------------------
ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "ztvps-ext-client"
boot_vm "${TMP_DIR}" "${QEMU_IMAGE}" 10 1024 1 ztvps-ext-client ztvps-ext-client "" \
    "hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22"

GUEST="ubuntu@127.0.0.1"
echo "[E2E] waiting for the client VM SSH..."
require_ssh_ready "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" 60

echo "[E2E] copying the client config and root CA into the VM"
cat "${TMP_DIR}/client.conf" | \
    run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    'cat > /tmp/zt-ext.conf && chmod 600 /tmp/zt-ext.conf'
cat "${ROOT_CA}" | \
    run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    'cat > /tmp/root.crt && chmod 600 /tmp/root.crt'

# --- in-VM verification -----------------------------------------------------------
echo "[E2E] installing wireguard-tools and bringing the tunnel up"
run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo bash -s" <<'RREMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq >/dev/null
sudo apt-get install -y -qq wireguard-tools dnsutils openssl >/dev/null 2>&1
[[ -e /dev/net/tun ]] || { echo "[FAIL] /dev/net/tun is missing" >&2; exit 1; }
sudo wg-quick up /tmp/zt-ext.conf
sleep 4

if ! ping -c 2 -W 4 10.66.0.2 >/dev/null 2>&1; then
    echo "[FAIL] AdGuard on the VPS (10.66.0.2) is not reachable over the real internet tunnel" >&2
    exit 1
fi
echo "[PASS] AdGuard reachable over the real internet tunnel"

echo "--- DNS via the VPS AdGuard (10.66.0.2) ---"
for d in wg.internal adguard.internal; do
    echo "  ${d} -> $(dig +short @10.66.0.2 "${d}" | tr '\n' ' ')"
done
dig +short @10.66.0.2 wg.internal | grep -q '^10\.66\.0\.3$' || { echo "[FAIL] DNS via the VPS AdGuard is wrong" >&2; exit 1; }

if ! curl -fsS --resolve "wg.internal:443:10.66.0.3" --cacert /tmp/root.crt \
    "https://wg.internal/" -o /dev/null; then
    echo "[FAIL] https://wg.internal not reachable over the real internet tunnel" >&2
    exit 1
fi
echo "[PASS] https://wg.internal reachable (trusted VPS private CA)"

if ! curl -fsS --resolve "adguard.internal:443:10.66.0.3" --cacert /tmp/root.crt \
    "https://adguard.internal/" -o /dev/null; then
    echo "[FAIL] https://adguard.internal not reachable over the real internet tunnel" >&2
    exit 1
fi
echo "[PASS] https://adguard.internal reachable (trusted VPS private CA)"

echo "--- certificate served by the VPS Caddy for wg.internal ---"
echo | openssl s_client -connect 10.66.0.3:443 -servername wg.internal \
    -CAfile /tmp/root.crt 2>/dev/null \
    | openssl x509 -noout -issuer -dates -ext subjectAltName 2>/dev/null \
    || echo "  cannot inspect the served certificate"

echo "--- WireGuard handshake with the real VPS ---"
wg show | grep -E 'interface:|endpoint:|handshake:|transfer:' || true

# egress through the VPS is informational (needs FULL_TUNNEL + VPS masquerade)
if ip route | grep -q '^default.*zt-ext'; then
    echo "--- internet egress through the VPS (full tunnel) ---"
    public_ip="$(curl -fsS --max-time 15 https://ifconfig.me 2>/dev/null || true)"
    echo "  egress IP via the tunnel: ${public_ip:-<unavailable>}"
fi

echo "[PASS] external WireGuard client -> real VPS E2E succeeded"
RREMOTE

# --- final report -----------------------------------------------------------------
echo "[E2E] PASS: real external client to ${VPS_HOST} succeeded"
if [[ "${KEEP_PEER}" == "1" ]]; then
    echo "[E2E] note: the test peer was kept on the VPS (KEEP_PEER=1); config in ${TMP_DIR}/client.conf (removed on exit)"
fi

