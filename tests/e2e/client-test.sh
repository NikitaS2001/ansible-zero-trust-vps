#!/usr/bin/env bash
# WireGuard client E2E test. Creates a client through the wg-easy API over an
# SSH tunnel, brings up wg-quick locally, and verifies DNS + internal HTTPS.
#
# Usage (via env):
#   TARGET=admin@host ADMIN_SSH_PORT=2222 SSH_KEY=~/.ssh/id_ed25519 \
#   WG_PASSWORD=<panel password> WG_ENDPOINT=203.0.113.10:51820 \
#   tests/e2e/client-test.sh
#
# Requires curl, jq, wireguard-tools, /dev/net/tun and root (for wg-quick).
set -euo pipefail

: "${TARGET:?TARGET is required (admin@host)}"
: "${SSH_KEY:?SSH_KEY is required}"
: "${WG_PASSWORD:?WG_PASSWORD is required}"

ADMIN_SSH_PORT="${ADMIN_SSH_PORT:-2222}"
WG_USER="${WG_USER:-admin}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
UI_PORT="${UI_PORT:-51821}"
CLIENT_NAME="${CLIENT_NAME:-e2e-client-$(date +%s)}"
ROOT_CA_REMOTE_PATH="${ROOT_CA_REMOTE_PATH:-/opt/zero-trust-vps-installer/repo/fetched_certs/localhost/root.crt}"

for tool in curl jq ssh sudo wg wg-quick; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "[FAIL] client-test requires ${tool}" >&2; exit 1; }
done
[[ -e /dev/net/tun ]] || { echo "[FAIL] /dev/net/tun is required on this machine" >&2; exit 1; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-client.XXXXXX")"
TUNNEL_PID=""
cleanup() {
    sudo wg-quick down "${TMP_DIR}/e2e.conf" >/dev/null 2>&1 || true
    [[ -n "${TUNNEL_PID}" ]] && kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

ssh_opts=(-p "${ADMIN_SSH_PORT}" -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)

# 1. SSH tunnel to the wg-easy UI on the VPS
ssh "${ssh_opts[@]}" -N -L "${UI_PORT}:127.0.0.1:${UI_PORT}" "${TARGET}" &
TUNNEL_PID=$!
sleep 2

# 2. Create a client through the wg-easy API (HTTP Basic auth)
create_ok=false
for _ in $(seq 1 12); do
    if curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X POST \
        "http://127.0.0.1:${UI_PORT}/api/client" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"${CLIENT_NAME}\",\"expiresAt\":null}" >"${TMP_DIR}/create.json" 2>/dev/null; then
        create_ok=true
        break
    fi
    sleep 5
done
[[ "${create_ok}" == "true" ]] || { echo "[FAIL] could not create a wg-easy client" >&2; exit 1; }
CLIENT_ID="$(jq -r '.clientId' "${TMP_DIR}/create.json" 2>/dev/null || true)"
[[ -n "${CLIENT_ID}" && "${CLIENT_ID}" != "null" ]] || { echo "[FAIL] wg-easy did not return a client id" >&2; exit 1; }

# 3. Fetch the client configuration
curl -fsS -u "${WG_USER}:${WG_PASSWORD}" \
    "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}/configuration" >"${TMP_DIR}/e2e.conf"
grep -q '^\[Interface\]' "${TMP_DIR}/e2e.conf" \
    || { echo "[FAIL] downloaded configuration is not a WireGuard config" >&2; exit 1; }

# 4. Optionally rewrite the endpoint (needed when testing through NAT/VM)
if [[ -n "${WG_ENDPOINT}" ]]; then
    sed -i -E "s|^Endpoint = .*|Endpoint = ${WG_ENDPOINT}|" "${TMP_DIR}/e2e.conf"
fi

# 5. Fetch the Caddy root CA from the VPS
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "${TARGET}" "cat '${ROOT_CA_REMOTE_PATH}'" >"${TMP_DIR}/root.crt" 2>/dev/null \
    || { echo "[FAIL] could not fetch the root CA from the VPS" >&2; exit 1; }

# 6. Bring up the tunnel
sudo wg-quick up "${TMP_DIR}/e2e.conf"
sleep 3

# 7. Verify DNS and internal HTTPS
if ! ping -c 2 -W 3 10.66.0.2 >/dev/null 2>&1; then
    echo "[FAIL] AdGuard (10.66.0.2) is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] AdGuard reachable over the VPN"

if ! curl -fsS --resolve "wg.internal:443:10.66.0.3" \
    --cacert "${TMP_DIR}/root.crt" "https://wg.internal/" -o /dev/null; then
    echo "[FAIL] https://wg.internal is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] https://wg.internal reachable over the VPN (trusted root CA)"

if ! curl -fsS --resolve "adguard.internal:443:10.66.0.3" \
    --cacert "${TMP_DIR}/root.crt" "https://adguard.internal/" -o /dev/null; then
    echo "[FAIL] https://adguard.internal is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] https://adguard.internal reachable over the VPN (trusted root CA)"

echo "[PASS] WireGuard client E2E succeeded"
