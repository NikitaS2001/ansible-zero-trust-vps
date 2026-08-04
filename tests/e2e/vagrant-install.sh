#!/usr/bin/env bash
# End-to-end test of the public installer inside a disposable Vagrant VM.
#
# Usage:
#   tests/e2e/vagrant-install.sh [--reboot-test] [--client-test]
#
# Env:
#   VAGRANT_BOX       base box (default ubuntu/noble64, e.g. debian/bookworm64)
#   INSTALL_REF       git ref to install (default: current branch)
#   E2E_SSH_PORT      hardened SSH port (default 2222)
#   E2E_WG_PORT       WireGuard UDP port (default 51820)
#   E2E_HOST_PORT_*   host-side forwarded ports (defaults in Vagrantfile)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

VAGRANT_BOX="${VAGRANT_BOX:-ubuntu/noble64}"
INSTALL_REF="${INSTALL_REF:-$(git rev-parse --abbrev-ref HEAD)}"
DO_REBOOT=false
DO_CLIENT_TEST=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        --client-test) DO_CLIENT_TEST=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
E2E_HOST_PORT_ADMIN_SSH="${E2E_HOST_PORT_ADMIN_SSH:-2222}"
E2E_HOST_PORT_WG_UDP="${E2E_HOST_PORT_WG_UDP:-51820}"

export VAGRANT_BOX INSTALL_REF \
    E2E_HOST_PORT_VAGRANT_SSH E2E_HOST_PORT_ADMIN_SSH \
    E2E_HOST_PORT_WG_UDP E2E_HOST_PORT_WG_UI E2E_HOST_PORT_ADGUARD_UI

command -v vagrant >/dev/null || fail "vagrant not found"
command -v ssh-keygen >/dev/null || fail "ssh-keygen not found"
command -v openssl >/dev/null || fail "openssl not found"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-e2e.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "e2e-ztvps"
PUBKEY="$(cat "${TMP_DIR}/id_ed25519.pub")"
ADMIN_PASS="$(openssl rand -hex 12)"
ADGUARD_PASS="$(openssl rand -hex 12)"
WG_PASS="$(openssl rand -hex 12)"

echo "[E2E] box=${VAGRANT_BOX} ref=${INSTALL_REF} ssh_port=${E2E_SSH_PORT} wg_port=${E2E_WG_PORT}"

echo "[E2E] Starting VM (first run downloads the base box)..."
vagrant up

echo "[E2E] Guest sanity: /dev/net/tun and wireguard module"
vagrant ssh -c 'test -e /dev/net/tun && echo tun-ok || echo tun-missing' || true
vagrant ssh -c 'modprobe wireguard 2>/dev/null && echo wg-mod-ok || echo wg-mod-missing' || true

echo "[E2E] Running the public installer non-interactively (repo=/vagrant, ref=${INSTALL_REF})"
vagrant ssh -c "
    sudo env \\
        ZERO_TRUST_NONINTERACTIVE=1 \\
        ZERO_TRUST_REPO_URL=/vagrant \\
        ZERO_TRUST_RELEASE_REF='${INSTALL_REF}' \\
        ZERO_TRUST_SSH_PORT='${E2E_SSH_PORT}' \\
        ZERO_TRUST_WG_PORT='${E2E_WG_PORT}' \\
        ZERO_TRUST_ADMIN_USER=sysadmin \\
        ZERO_TRUST_ADMIN_PASSWORD='${ADMIN_PASS}' \\
        ZERO_TRUST_ADGUARD_PASSWORD='${ADGUARD_PASS}' \\
        ZERO_TRUST_WG_PASSWORD='${WG_PASS}' \\
        ZERO_TRUST_INTERNAL_DOMAINS='wg.internal adguard.internal' \\
        ZERO_TRUST_SSH_PUBKEY='${PUBKEY}' \\
        bash /vagrant/install.sh
"

# Resolve how to reach the guest from this host: libvirt exposes the guest IP
# directly; VirtualBox NAT only exposes forwarded ports on 127.0.0.1.
ssh_config="$(vagrant ssh-config)"
hostname="$(awk '/HostName/ {print $2; exit}' <<<"${ssh_config}")"
if [[ "${hostname}" == "127.0.0.1" || "${hostname}" == "localhost" ]]; then
    ADMIN_TARGET="sysadmin@127.0.0.1"
    ADMIN_PORT="${E2E_HOST_PORT_ADMIN_SSH}"
    WG_ENDPOINT="127.0.0.1:${E2E_HOST_PORT_WG_UDP}"
else
    ADMIN_TARGET="sysadmin@${hostname}"
    ADMIN_PORT="${E2E_SSH_PORT}"
    WG_ENDPOINT="${hostname}:${E2E_WG_PORT}"
fi

echo "[E2E] Verifying the deployed stack via ${ADMIN_TARGET}:${ADMIN_PORT}"
export E2E_SSH_PORT E2E_WG_PORT
verify_deployment "${ADMIN_TARGET}" "${ADMIN_PORT}" "${TMP_DIR}/id_ed25519"

if [[ "${DO_REBOOT}" == "true" ]]; then
    echo "[E2E] Rebooting the guest and re-verifying..."
    run_remote "${ADMIN_TARGET}" "${ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 'sudo systemctl reboot' || true
    require_ssh_down "${ADMIN_TARGET}" "${ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 30
    require_ssh_ready "${ADMIN_TARGET}" "${ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 60
    sleep 20
    verify_deployment "${ADMIN_TARGET}" "${ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Reboot survival verified"
fi

if [[ "${DO_CLIENT_TEST}" == "true" ]]; then
    echo "[E2E] Running the WireGuard client test..."
    TARGET="${ADMIN_TARGET}" ADMIN_SSH_PORT="${ADMIN_PORT}" SSH_KEY="${TMP_DIR}/id_ed25519" \
        WG_PASSWORD="${WG_PASS}" WG_ENDPOINT="${WG_ENDPOINT}" \
        "${E2E_DIR}/client-test.sh"
fi

echo "[E2E] PASS: public installer E2E succeeded on ${VAGRANT_BOX}"
