#!/usr/bin/env bash
# End-to-end test of the public installer inside a plain qemu/KVM VM.
# Needs only qemu, KVM support and genisoimage (no libvirt daemon).
#
# Usage:
#   tests/e2e/qemu-install.sh [--reboot-test] [--client-test]
#
# Env:
#   QEMU_IMAGE       cloud image URL or local .img/.qcow2 path
#                    (default: Ubuntu 24.04 noble server cloud image)
#   QEMU_USER        initial login user created by cloud-init (default ubuntu)
#   INSTALL_REF      git ref to install (default: current branch)
#   E2E_SSH_PORT     hardened SSH port configured by the installer (default 2222)
#   E2E_WG_PORT      WireGuard UDP port configured by the installer (default 51820)
#   QEMU_SSH_PORT    host tcp port -> guest:22  (default 2223)
#   QEMU_ADMIN_PORT  host tcp port -> guest:<E2E_SSH_PORT> (default 2222)
#   QEMU_WG_PORT     host udp port -> guest:<E2E_WG_PORT> (default 51822)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

DEFAULT_IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
QEMU_IMAGE="${QEMU_IMAGE:-${DEFAULT_IMAGE}}"
QEMU_USER="${QEMU_USER:-ubuntu}"
INSTALL_REF="${INSTALL_REF:-$(git rev-parse --abbrev-ref HEAD)}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2223}"
QEMU_ADMIN_PORT="${QEMU_ADMIN_PORT:-2222}"
QEMU_WG_PORT="${QEMU_WG_PORT:-51822}"

DO_REBOOT=false
DO_CLIENT_TEST=false
DO_IDEMPOTENCY=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        --client-test) DO_CLIENT_TEST=true ;;
        --idempotency-test) DO_IDEMPOTENCY=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

for tool in qemu-system-x86_64 qemu-img genisoimage curl ssh-keygen openssl; do
    command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done
command -v ssh >/dev/null || fail "required tool not found: ssh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-qemu.XXXXXX")"
QEMU_PID=""
cleanup() {
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
        sleep 2
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# --- test fixtures ----------------------------------------------------------
ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "e2e-ztvps"
PUBKEY="$(cat "${TMP_DIR}/id_ed25519.pub")"
ADMIN_PASS="$(openssl rand -hex 12)"
ADGUARD_PASS="$(openssl rand -hex 12)"
WG_PASS="$(openssl rand -hex 12)"

echo "[E2E] image=${QEMU_IMAGE}"
echo "[E2E] ref=${INSTALL_REF} ssh_port=${E2E_SSH_PORT} wg_port=${E2E_WG_PORT} user=${QEMU_USER}"

# --- guest image + cloud-init seed + boot ------------------------------------
boot_vm "${TMP_DIR}" "${QEMU_IMAGE}" 20 2048 2 ztvps-e2e ztvps-e2e "" \
    "hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22" \
    "hostfwd=tcp:127.0.0.1:${QEMU_ADMIN_PORT}-:${E2E_SSH_PORT}" \
    "hostfwd=udp:127.0.0.1:${QEMU_WG_PORT}-:${E2E_WG_PORT}"

GUEST="${QEMU_USER}@127.0.0.1"
echo "[E2E] Waiting for cloud-init to finish (SSH on guest:22)..."
require_ssh_ready "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" 60

# --- copy the repo into the guest -------------------------------------------
echo "[E2E] Copying the repository into the guest..."
tar czf - -C "${ROOT_DIR}" . | \
    run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    'mkdir -p /tmp/ztrepo && tar xzf - -C /tmp/ztrepo'

# --- run the public installer (non-interactive) ------------------------------
echo "[E2E] Running the public installer non-interactively (repo=/tmp/ztrepo, ref=${INSTALL_REF})"
run_remote "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    "cd /tmp/ztrepo && sudo env \\
        ZERO_TRUST_NONINTERACTIVE=1 \\
        ZERO_TRUST_REPO_URL=/tmp/ztrepo \\
        ZERO_TRUST_RELEASE_REF='${INSTALL_REF}' \\
        ZERO_TRUST_SSH_PORT='${E2E_SSH_PORT}' \\
        ZERO_TRUST_WG_PORT='${E2E_WG_PORT}' \\
        ZERO_TRUST_ADMIN_USER=sysadmin \\
        ZERO_TRUST_ADMIN_PASSWORD='${ADMIN_PASS}' \\
        ZERO_TRUST_ADGUARD_PASSWORD='${ADGUARD_PASS}' \\
        ZERO_TRUST_WG_PASSWORD='${WG_PASS}' \\
        ZERO_TRUST_INTERNAL_DOMAINS='${WG_INTERNAL_DOMAIN:-wg.internal} ${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}' \\
        ZERO_TRUST_SSH_PUBKEY='${PUBKEY}' \\
        ZERO_TRUST_WG_HOST=127.0.0.1 \\
        bash ./install.sh"

echo "[E2E] Verifying the deployed stack on the hardened SSH port ${QEMU_ADMIN_PORT}"
export E2E_SSH_PORT E2E_WG_PORT
verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"

if [[ "${DO_REBOOT}" == "true" ]]; then
    echo "[E2E] Rebooting the VM and re-verifying..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo systemctl reboot' || true
    require_ssh_down "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 60
    require_ssh_ready "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 60
    sleep 20
    verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Reboot survival verified"
fi

if [[ "${DO_CLIENT_TEST}" == "true" ]]; then
    echo "[E2E] Installing wireguard-tools and jq in the guest..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo apt-get update -qq >/dev/null && sudo apt-get install -y -qq wireguard-tools jq openssl dnsutils resolvconf >/dev/null'
    echo "[E2E] Running the in-guest WireGuard client handshake test..."
    run_remote_stdin "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo WG_PASSWORD='${WG_PASS}' WG_ENDPOINT='127.0.0.1:${E2E_WG_PORT}' WG_INTERNAL_DOMAIN='${WG_INTERNAL_DOMAIN:-wg.internal}' ADGUARD_INTERNAL_DOMAIN='${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}' bash -s" \
        < "${E2E_DIR}/client-in-guest.sh"
fi

if [[ "${DO_IDEMPOTENCY}" == "true" ]]; then
    echo "[E2E] Re-copying the repository into the guest (the reboot clears /tmp)..."
    tar czf - -C "${ROOT_DIR}" . | \
        run_remote_stdin "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'mkdir -p /tmp/ztrepo && tar xzf - -C /tmp/ztrepo'
    echo "[E2E] Re-running the installer to verify idempotency..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "cd /tmp/ztrepo && sudo env \
        ZERO_TRUST_NONINTERACTIVE=1 \
        ZERO_TRUST_REPO_URL=/tmp/ztrepo \
        ZERO_TRUST_RELEASE_REF='${INSTALL_REF}' \
        ZERO_TRUST_SSH_PORT='${E2E_SSH_PORT}' \
        ZERO_TRUST_WG_PORT='${E2E_WG_PORT}' \
        ZERO_TRUST_ADMIN_USER=sysadmin \
        ZERO_TRUST_ADMIN_PASSWORD='${ADMIN_PASS}' \
        ZERO_TRUST_ADGUARD_PASSWORD='${ADGUARD_PASS}' \
        ZERO_TRUST_WG_PASSWORD='${WG_PASS}' \
        ZERO_TRUST_INTERNAL_DOMAINS='wg.internal adguard.internal' \
        ZERO_TRUST_SSH_PUBKEY='${PUBKEY}' \
        ZERO_TRUST_WG_HOST=127.0.0.1 \
        bash ./install.sh"
    echo "[E2E] Verifying the stack after the second installer run..."
    verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Idempotency verified"
fi

echo "[E2E] PASS: public installer E2E succeeded in qemu/KVM"
