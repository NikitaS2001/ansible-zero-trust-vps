#!/usr/bin/env bash
# In-guest WireGuard client E2E. Runs inside the deployed VM/VPS: creates a
# client through the wg-easy API on 127.0.0.1, brings up wg-quick locally,
# and verifies DNS + internal HTTPS endpoints through the VPN.
#
# Env:
#   WG_PASSWORD   wg-easy panel password (required)
#   WG_USER       panel username (default admin)
#   WG_ENDPOINT   endpoint to use in the client config (default 127.0.0.1:<wg port>)
#   ROOT_CA       path to the fetched Caddy root CA (default installer path)
set -euo pipefail

: "${WG_PASSWORD:?WG_PASSWORD is required}"
WG_USER="${WG_USER:-admin}"
WG_ENDPOINT="${WG_ENDPOINT:-127.0.0.1:51820}"
ROOT_CA="${ROOT_CA:-/opt/zero-trust-vps-installer/repo/fetched_certs/localhost/root.crt}"
CLIENT_NAME="e2e-client-$(date +%s)"
UI_PORT="${UI_PORT:-51821}"

command -v curl >/dev/null || { echo "[FAIL] curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "[FAIL] jq is required" >&2; exit 1; }
command -v wg-quick >/dev/null || { echo "[FAIL] wireguard-tools are required" >&2; exit 1; }
[[ -e /dev/net/tun ]] || { echo "[FAIL] /dev/net/tun is missing" >&2; exit 1; }

cleanup() {
    sudo wg-quick down /tmp/zt-e2e.conf >/dev/null 2>&1 || true
    if [[ -n "${CLIENT_ID:-}" ]]; then
        # remove the test client from the wg-easy API so no peer is left behind
        curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X DELETE \
            "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}" >/dev/null 2>&1 || true
    fi
    rm -f /tmp/zt-e2e.conf /tmp/zt-create.json
}
trap cleanup EXIT

# 1. create a client through the wg-easy API (HTTP Basic auth)
create_ok=false
for _ in $(seq 1 12); do
    if curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X POST \
        "http://127.0.0.1:${UI_PORT}/api/client" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"${CLIENT_NAME}\",\"expiresAt\":null}" >/tmp/zt-create.json 2>/dev/null; then
        create_ok=true
        break
    fi
    sleep 5
done
[[ "${create_ok}" == "true" ]] || { echo "[FAIL] could not create a wg-easy client (check WG_PASSWORD)" >&2; exit 1; }
CLIENT_ID="$(jq -r '.clientId' /tmp/zt-create.json 2>/dev/null || true)"
[[ -n "${CLIENT_ID}" && "${CLIENT_ID}" != "null" ]] || { echo "[FAIL] wg-easy did not return a client id" >&2; exit 1; }

# 2. fetch the client configuration and point it at the local endpoint
curl -fsS -u "${WG_USER}:${WG_PASSWORD}" \
    "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}/configuration" >/tmp/zt-e2e.conf
grep -q '^\[Interface\]' /tmp/zt-e2e.conf || { echo "[FAIL] downloaded configuration is not a WireGuard config" >&2; exit 1; }
chmod 0600 /tmp/zt-e2e.conf
sed -i -E "s|^Endpoint = .*|Endpoint = ${WG_ENDPOINT}|" /tmp/zt-e2e.conf

# 3. bring the tunnel up
sudo wg-quick up /tmp/zt-e2e.conf
sleep 3

# 4. verify: AdGuard DNS, then internal HTTPS with the trusted root CA
if ! ping -c 2 -W 3 10.66.0.2 >/dev/null 2>&1; then
    echo "[FAIL] AdGuard (10.66.0.2) is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] AdGuard reachable over the VPN"

if ! curl -fsS --resolve "wg.internal:443:10.66.0.3" \
    --cacert "${ROOT_CA}" "https://wg.internal/" -o /dev/null; then
    echo "[FAIL] https://wg.internal is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] https://wg.internal reachable (trusted root CA)"

if ! curl -fsS --resolve "adguard.internal:443:10.66.0.3" \
    --cacert "${ROOT_CA}" "https://adguard.internal/" -o /dev/null; then
    echo "[FAIL] https://adguard.internal is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] https://adguard.internal reachable (trusted root CA)"

echo "--- diagnostics: private CA, local domains, WireGuard handshake ---"
echo "DNS resolution via AdGuard (10.66.0.2):"
for d in wg.internal adguard.internal; do
    echo "  ${d} -> $(dig +short @10.66.0.2 "${d}" | tr '\n' ' ')"
done
echo "Private root CA fetched from the server:"
openssl x509 -in "${ROOT_CA}" -noout -subject -issuer -dates 2>/dev/null \
    || echo "  cannot read the root CA"
echo "Certificate served by Caddy for wg.internal:"
echo | openssl s_client -connect 10.66.0.3:443 -servername wg.internal \
    -CAfile "${ROOT_CA}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
    || echo "  cannot inspect the served certificate"
echo "WireGuard client interface (handshake / transfer):"
wg show | grep -E 'interface:|handshake:|transfer:' || true

echo "[PASS] in-guest WireGuard client E2E succeeded"
