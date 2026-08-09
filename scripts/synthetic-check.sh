#!/usr/bin/env bash
# Synthetic health check for the zero-trust stack. Run on the VPS as root
# (e.g. via cron/systemd.timer). Catches "running but broken" states that
# restart policies miss: container health, internal HTTPS via Caddy, and
# WireGuard handshake freshness.
#
# A full *external* VPN->DNS->HTTPS check requires a real client; see
# tests/e2e/external-client-qemu.sh (manual) for that path.
set -euo pipefail

WG_INTERNAL_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.internal}"
ADGUARD_INTERNAL_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"
CADDY_IP="$(docker inspect -f '{{.NetworkSettings.Networks.vpn_net.IPAddress}}' caddy 2>/dev/null || true)"

fail() { echo "[FAIL] $*" >&2; exit 1; }

echo "== containers =="
for c in wg-easy adguard caddy; do
    state="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo missing)"
    case "${state}" in
        healthy) echo "[OK] ${c} healthy" ;;
        "")      echo "[OK] ${c} up (no healthcheck configured)" ;;
        *)       fail "container ${c} is ${state}" ;;
    esac
done

echo "== HTTPS via Caddy (internal CA) =="
[[ -n "${CADDY_IP}" ]] || fail "could not determine the Caddy container IP"
for d in "${WG_INTERNAL_DOMAIN}" "${ADGUARD_INTERNAL_DOMAIN}"; do
    code="$(curl -kso /dev/null -w '%{http_code}' --resolve "${d}:443:${CADDY_IP}" "https://${d}/" 2>/dev/null || true)"
    case "${code}" in
        200|302|401) echo "[OK] HTTPS ${d} -> ${code}" ;;
        *) fail "HTTPS ${d} returned '${code}'" ;;
    esac
done

echo "== WireGuard handshake freshness =="
latest="$(docker exec wg-easy wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -rn | head -1 || true)"
now="$(date +%s)"
if [[ -n "${latest}" ]] && [[ $((now - latest)) -lt 3600 ]]; then
    echo "[OK] recent WireGuard handshake (<= 1h)"
else
    echo "[WARN] no WireGuard handshake in the last hour"
fi

echo "[PASS] synthetic check"
