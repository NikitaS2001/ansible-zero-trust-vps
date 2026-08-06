#!/usr/bin/env bash
# Final E2E against a real VPS using the public installer exactly as documented:
#
#   curl -fsSL https://raw.githubusercontent.com/<repo>/<tag>/install.sh | sudo bash
#
# Usage:
#   VPS_IP=... VPS_SSH_KEY=... INSTALL_REF=v1.0.0 tests/e2e/run-public-install.sh [--reboot-test] [--client-test]
#
# Required env:
#   VPS_IP        public IP of a fresh VPS with root SSH access
#   VPS_SSH_KEY   identity file for root SSH access
#   INSTALL_REF   git tag or branch to install (e.g. v1.0.0)
# Optional env:
#   VPS_SSH_PORT (default 22), VPS_ROOT_USER (default root),
#   ZERO_TRUST_* installer inputs, E2E_SSH_PORT (default 2222), E2E_WG_PORT (default 51820)
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${E2E_DIR}/../.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

: "${VPS_IP:?VPS_IP is required}"
: "${VPS_SSH_KEY:?VPS_SSH_KEY is required}"
: "${INSTALL_REF:?INSTALL_REF is required}"

VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
VPS_ROOT_USER="${VPS_ROOT_USER:-root}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
DO_REBOOT=false
DO_CLIENT_TEST=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        --client-test) DO_CLIENT_TEST=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

ROOT_TARGET="${VPS_ROOT_USER}@${VPS_IP}"
command -v ssh-keygen >/dev/null || fail "ssh-keygen not found"
command -v openssl >/dev/null || fail "openssl not found"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-vps.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "e2e-ztvps"
PUBKEY="$(cat "${TMP_DIR}/id_ed25519.pub")"

ADMIN_USER="${ZERO_TRUST_ADMIN_USER:-sysadmin}"
ADMIN_PASS="${ZERO_TRUST_ADMIN_PASSWORD:-$(openssl rand -hex 12)}"
ADGUARD_PASS="${ZERO_TRUST_ADGUARD_PASSWORD:-$(openssl rand -hex 12)}"
WG_PASS="${ZERO_TRUST_WG_PASSWORD:-$(openssl rand -hex 12)}"
SSH_PORT_IN="${ZERO_TRUST_SSH_PORT:-${E2E_SSH_PORT}}"
WG_PORT_IN="${ZERO_TRUST_WG_PORT:-${E2E_WG_PORT}}"
INTERNAL_DOMAINS="${ZERO_TRUST_INTERNAL_DOMAINS:-wg.internal adguard.internal}"

echo "[E2E] Waiting for root SSH on ${ROOT_TARGET}:${VPS_SSH_PORT}"
require_ssh_ready "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" 30

INSTALL_URL="https://raw.githubusercontent.com/NikitaS2001/ansible-zero-trust-vps/${INSTALL_REF}/install.sh"
echo "[E2E] Running the public installer from ${INSTALL_URL}"

REMOTE_INSTALL=$(cat <<INNER_EOF
set -euo pipefail
curl -fsSL '${INSTALL_URL}' |
sudo env \\
    ZERO_TRUST_NONINTERACTIVE=1 \\
    ZERO_TRUST_REPO_URL=https://github.com/NikitaS2001/ansible-zero-trust-vps.git \\
    ZERO_TRUST_RELEASE_REF='${INSTALL_REF}' \\
    ZERO_TRUST_SSH_PORT='${SSH_PORT_IN}' \\
    ZERO_TRUST_WG_PORT='${WG_PORT_IN}' \\
    ZERO_TRUST_ADMIN_USER='${ADMIN_USER}' \\
    ZERO_TRUST_ADMIN_PASSWORD='${ADMIN_PASS}' \\
    ZERO_TRUST_ADGUARD_PASSWORD='${ADGUARD_PASS}' \\
    ZERO_TRUST_WG_PASSWORD='${WG_PASS}' \\
    ZERO_TRUST_INTERNAL_DOMAINS='${INTERNAL_DOMAINS}' \\
    ZERO_TRUST_SSH_PUBKEY='${PUBKEY}' \\
    bash
INNER_EOF
)
run_remote_stdin "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" 'bash -s' <<<"${REMOTE_INSTALL}"

echo "[E2E] Verifying the deployed stack on the hardened SSH port ${SSH_PORT_IN}"
export E2E_SSH_PORT="${SSH_PORT_IN}" E2E_WG_PORT="${WG_PORT_IN}"
verify_deployment "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${TMP_DIR}/id_ed25519"

if [[ "${DO_REBOOT}" == "true" ]]; then
    echo "[E2E] Rebooting ${VPS_IP} and re-verifying..."
    run_remote "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${TMP_DIR}/id_ed25519" 'sudo systemctl reboot' || true
    require_ssh_down "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${TMP_DIR}/id_ed25519" 30
    require_ssh_ready "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${TMP_DIR}/id_ed25519" 60
    sleep 20
    verify_deployment "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Reboot survival verified"
fi

if [[ "${DO_CLIENT_TEST}" == "true" ]]; then
    echo "[E2E] Installing wireguard-tools and jq on the VPS..."
    run_remote "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${TMP_DIR}/id_ed25519" \
        'sudo apt-get update -qq >/dev/null && sudo apt-get install -y -qq wireguard-tools jq openssl dnsutils >/dev/null'
    echo "[E2E] Running the in-guest WireGuard client handshake test..."
    run_remote_stdin "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${TMP_DIR}/id_ed25519" \
        "sudo WG_PASSWORD='${WG_PASS}' WG_ENDPOINT='127.0.0.1:${WG_PORT_IN}' bash -s" \
        < "${E2E_DIR}/client-in-guest.sh"
fi

echo "[E2E] PASS: public installer E2E succeeded for ${VPS_IP} (${INSTALL_REF})"
