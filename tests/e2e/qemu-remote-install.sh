#!/usr/bin/env bash
# Remote-mode E2E of the playbook inside a plain qemu/KVM VM.
# The VM plays the role of a fresh VPS; this host plays the Ansible controller
# and deploys with the documented remote mode (inventory + group_vars + vault,
# ansible-playbook over SSH) - not with the public installer.
#
# Usage:
#   tests/e2e/qemu-remote-install.sh [--reboot-test]
#
# Env:
#   QEMU_IMAGE          cloud image URL or local path (default Ubuntu 24.04)
#   INSTALL_REF         ignored (uses the working tree); kept for symmetry
#   E2E_SSH_PORT        hardened SSH port configured by the playbook (2222)
#   E2E_WG_PORT         WireGuard UDP port configured by the playbook (51820)
#   QEMU_SSH_PORT       host tcp -> guest:22   (2223)
#   QEMU_ADMIN_PORT     host tcp -> guest:<E2E_SSH_PORT> (2222)
#   QEMU_WG_PORT        host udp -> guest:<E2E_WG_PORT> (51822)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

DEFAULT_IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
QEMU_IMAGE="${QEMU_IMAGE:-${DEFAULT_IMAGE}}"
INSTALL_REF="${INSTALL_REF:-feat/public-installer-v1}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2223}"
QEMU_ADMIN_PORT="${QEMU_ADMIN_PORT:-2222}"
QEMU_WG_PORT="${QEMU_WG_PORT:-51822}"

DO_REBOOT=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

for tool in qemu-system-x86_64 qemu-img genisoimage curl ssh-keygen openssl ansible-playbook ansible-vault; do
    command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-remote.XXXXXX")"
QEMU_PID=""
cleanup() {
    # remove the controller files written into the repo (all gitignored)
    rm -f "${ROOT_DIR}/inventory/hosts.yml"
    rm -f "${ROOT_DIR}/group_vars/all/vars.yml"
    rm -f "${ROOT_DIR}/group_vars/all/vault_ssh.yml"
    rm -f "${ROOT_DIR}/group_vars/all/vault_services.yml"
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
        sleep 2
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# --- test fixtures ----------------------------------------------------------
ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "e2e-ztvps-remote"
PUBKEY="$(cat "${TMP_DIR}/id_ed25519.pub")"
ADGUARD_PASS="$(openssl rand -hex 12)"
WG_PASS="$(openssl rand -hex 12)"
ADGUARD_HASH="$(python3 - <<PY
from passlib.hash import bcrypt
print(bcrypt.using(ident='2y', rounds=10).hash('${ADGUARD_PASS}'))
PY
)"

# --- guest image + seed (root SSH for the controller) -------------------------
IMG="${TMP_DIR}/cloud.img"
if [[ "${QEMU_IMAGE}" == http* ]]; then
    curl -fL --retry 3 -o "${IMG}" "${QEMU_IMAGE}"
else
    cp "${QEMU_IMAGE}" "${IMG}"
fi
DISK="${TMP_DIR}/disk.qcow2"
qemu-img create -f qcow2 -b "${IMG}" -F qcow2 "${DISK}" 20G >/dev/null

SEED_DIR="${TMP_DIR}/seed"
mkdir -p "${SEED_DIR}"
cat >"${SEED_DIR}/meta-data" <<'SEEDEOF'
instance-id: ztvps-remote-e2e
local-hostname: ztvps-remote
SEEDEOF
cat >"${SEED_DIR}/user-data" <<SEEDEOF
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - ${PUBKEY}
    lock_passwd: true
SEEDEOF
SEED_ISO="${TMP_DIR}/seed.iso"
genisoimage -quiet -output "${SEED_ISO}" -volid cidata -joliet -rock "${SEED_DIR}"

echo "[E2E] Booting the VM (KVM)..."
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
    -drive file="${DISK}",if=virtio,format=qcow2 \
    -drive file="${SEED_ISO}",if=virtio,format=raw \
    -netdev user,id=n0,\
hostfwd=tcp:127.0.0.1:"${QEMU_SSH_PORT}"-:22,\
hostfwd=tcp:127.0.0.1:"${QEMU_ADMIN_PORT}"-:"${E2E_SSH_PORT}",\
hostfwd=udp:127.0.0.1:"${QEMU_WG_PORT}"-:"${E2E_WG_PORT}" \
    -device virtio-net-pci,netdev=n0 \
    -display none -serial file:"${TMP_DIR}/serial.log" \
    -daemonize -pidfile "${TMP_DIR}/qemu.pid"
sleep 2
if [[ ! -s "${TMP_DIR}/qemu.pid" ]]; then
    echo "[FAIL] qemu did not start. Serial log:" >&2
    tail -30 "${TMP_DIR}/serial.log" 2>/dev/null || true
    exit 1
fi
QEMU_PID="$(cat "${TMP_DIR}/qemu.pid")"

echo "[E2E] Waiting for root SSH on guest:22 (host port ${QEMU_SSH_PORT})..."
require_ssh_ready "root@127.0.0.1" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" 60

# --- controller side: inventory + group_vars + vault --------------------------
# These paths are gitignored in the repo, exactly like a real remote deploy.
cat >"${ROOT_DIR}/inventory/hosts.yml" <<EOF
---
all:
  children:
    vps:
      hosts:
        vps01:
          ansible_host: 127.0.0.1
          ansible_port: ${QEMU_SSH_PORT}
          ansible_user: root
          ansible_ssh_private_key_file: ${TMP_DIR}/id_ed25519
          ansible_python_interpreter: /usr/bin/python3
EOF
cat >"${ROOT_DIR}/group_vars/all/vars.yml" <<EOF
---
# Network
ssh_port: ${E2E_SSH_PORT}
wg_port: ${E2E_WG_PORT}
wg_container_port: ${E2E_WG_PORT}
wg_vpn_subnet: "10.8.0.0/24"
wg_server_ip: "10.8.0.1"
wg_client_dns: "10.66.0.2"

# wg-easy initial setup (INIT_*)
wg_easy_admin_user: "admin"
wg_easy_admin_password: "${WG_PASS}"
wg_public_host: "127.0.0.1"
wg_allowed_ips:
  - "10.8.0.0/24"
  - "10.66.0.2/32"
  - "10.66.0.3/32"

# Docker network
docker_network_subnet: "10.66.0.0/24"
adguard_container_ip: "10.66.0.2"
caddy_container_ip: "10.66.0.3"
wg_easy_container_ip: "10.66.0.4"

# Internal domains and UI ports
wg_internal_domain: "wg.internal"
adguard_internal_domain: "adguard.internal"
wg_easy_bootstrap_ui_port: 51821
adguard_bootstrap_ui_port: 3000

# Remote host paths
project_root: "/opt/zero-trust-vps"

# Admin user
admin_user: "sysadmin"
admin_shell: "/bin/bash"
ssh_service_name: "ssh"
ssh_allow_tcp_forwarding: "yes"
EOF
cat >"${ROOT_DIR}/group_vars/all/vault_ssh.yml" <<EOF
---
vault_admin_ssh_pubkey: "${PUBKEY}"
EOF
cat >"${ROOT_DIR}/group_vars/all/vault_services.yml" <<EOF
---
vault_adguard_password_hash: "${ADGUARD_HASH}"
EOF
echo 'test-vault-password' >"${TMP_DIR}/vault_pass"
chmod 0600 "${TMP_DIR}/vault_pass"
ansible-vault encrypt --vault-password-file "${TMP_DIR}/vault_pass" \
    "${ROOT_DIR}/group_vars/all/vault_ssh.yml" \
    "${ROOT_DIR}/group_vars/all/vault_services.yml"

echo "[E2E] Running the playbook in remote mode (controller -> VM)..."
ANSIBLE_HOST_KEY_CHECKING=False \
    ansible-playbook -i "${ROOT_DIR}/inventory/hosts.yml" \
    --vault-password-file "${TMP_DIR}/vault_pass" site.yml

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

echo "[E2E] PASS: remote-mode E2E succeeded in qemu/KVM"
