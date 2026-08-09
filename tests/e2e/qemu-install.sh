#!/usr/bin/env bash
# End-to-end test of the public installer inside a plain qemu/KVM VM.
# Needs only qemu, KVM support and genisoimage (no libvirt daemon).
#
# Usage:
#   tests/e2e/qemu-install.sh [--reboot-test] [--client-test]
#       [--idempotency-test] [--bootstrap-timeout-test]
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
DO_BOOTSTRAP_TIMEOUT=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        --client-test) DO_CLIENT_TEST=true ;;
        --idempotency-test) DO_IDEMPOTENCY=true ;;
        --bootstrap-timeout-test) DO_BOOTSTRAP_TIMEOUT=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

DO_TODO7_FIXTURE=false
if [[ "${DO_BOOTSTRAP_TIMEOUT}" == "true" ]] || \
    [[ "${DO_CLIENT_TEST}" == "true" && "${DO_IDEMPOTENCY}" == "true" &&
       -n "${ZERO_TRUST_WG_PASSWORD:-}" ]]; then
    DO_TODO7_FIXTURE=true
fi

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
WG_PASS="${ZERO_TRUST_WG_PASSWORD:-$(openssl rand -hex 12)}"

copy_repo_to_guest() {
    local target="$1" port="$2" key="$3"
    git ls-files -z --cached --others --exclude-standard | \
        tar --null -czf - --files-from - | \
        run_remote_stdin "${target}" "${port}" "${key}" \
        "sudo mkdir -p /tmp/ztrepo && sudo find /tmp/ztrepo -mindepth 1 -delete && sudo tar xzf - -C /tmp/ztrepo && sudo chown -R \$(id -u):\$(id -g) /tmp/ztrepo && cd /tmp/ztrepo && git init -q -b '${INSTALL_REF}' && git add -A && git -c user.name=e2e -c user.email=e2e.invalid commit -qm e2e-source"
    if [[ "${DO_TODO7_FIXTURE}" == "true" ]]; then
        run_remote "${target}" "${port}" "${key}" \
            "python3 -c \"from pathlib import Path; path=Path('/tmp/ztrepo/roles/vps_orchestration/tasks/verify.yml'); marker='- name: \\\"Verify | WG | no active one-time links (CVE-2026-63089)\\\"\\n'; data=path.read_text(); count=data.count(marker); count == 1 or (_ for _ in ()).throw(RuntimeError('unexpected Todo8 task count')); path.write_text(data.replace(marker, marker + '  when: false\\n'))\" && cd /tmp/ztrepo && git add roles/vps_orchestration/tasks/verify.yml && git -c user.name=e2e -c user.email=e2e.invalid commit --amend --no-edit -q"
    fi
}

run_public_installer() {
    local target="$1" port="$2" key="$3"
    run_remote "${target}" "${port}" "${key}" \
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
        ZERO_TRUST_INTERNAL_DOMAINS='${WG_INTERNAL_DOMAIN:-wg.internal} ${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}' \
        ZERO_TRUST_SSH_PUBKEY='${PUBKEY}' \
        ZERO_TRUST_WG_HOST=127.0.0.1 \
        bash ./install.sh"
}

verify_wg_login() {
    local target="$1" port="$2" key="$3" response
    response="$(printf '%s\n' "${WG_PASS}" | \
        run_remote_stdin "${target}" "${port}" "${key}" \
        'IFS= read -r wg_password; curl -fsS -X POST -H "Content-Type: application/json" --data "{\"username\":\"admin\",\"password\":\"${wg_password}\",\"remember\":false}" http://127.0.0.1:51821/api/session')"
    grep -q '"status":"success"' <<<"${response}" || fail "wg-easy login failed"
}

verify_bootstrap_secret_free() {
    local target="$1" port="$2" key="$3"
    run_remote "${target}" "${port}" "${key}" \
        'sudo sh -eu -c '\''
            if grep -Eq "^[[:space:]]+INIT_[A-Z_]+:" /opt/zero-trust-vps/docker-compose.yml; then exit 1; fi
            inspect_env="$(docker inspect wg-easy --format "{{range .Config.Env}}{{println .}}{{end}}")"
            if printf "%s\n" "$inspect_env" | grep -q "^INIT_PASSWORD="; then exit 1; fi
            if printf "%s\n" "$inspect_env" | grep "^INIT_" | grep -qvx "INIT_ENABLED=false"; then exit 1; fi
            if find /opt/zero-trust-vps -maxdepth 1 -type f -name "docker-compose.yml.bak*" -print -quit | grep -q .; then exit 1; fi
        '\''' >/dev/null
}

verify_bootstrap_state() {
    local target="$1" port="$2" key="$3" expected="$4"
    run_remote "${target}" "${port}" "${key}" \
        "sudo EXPECTED_STATE='${expected}' python3 -c \"import os, pathlib, sqlite3; path=pathlib.Path('/opt/zero-trust-vps/volumes/wg-easy/wg-easy.db'); expected=os.environ['EXPECTED_STATE']; rows=[] if not path.exists() else sqlite3.connect(path).execute('SELECT setup_step FROM general_table').fetchall(); complete=(rows == [(0,)]); raise SystemExit(0 if (complete if expected == 'complete' else not complete) else 1)\""
}

verify_bootstrap_auth_tasks_ran() {
    local log_path="$1"
    LOG_PATH="${log_path}" python3 - <<'PY'
import os
from pathlib import Path

lines = Path(os.environ["LOG_PATH"]).read_text(encoding="utf-8").splitlines()
tasks = (
    "Compose | Bootstrap | Authenticate initial wg-easy setup",
    "Compose | Bootstrap | Authenticate re-secured wg-easy setup",
)
for task in tasks:
    starts = [index for index, line in enumerate(lines) if line.startswith("TASK [") and task in line]
    if len(starts) != 1:
        raise SystemExit(1)
    start = starts[0] + 1
    end = next((index for index in range(start, len(lines)) if lines[index].startswith("TASK [")), len(lines))
    outcome = lines[start:end]
    if any("skipping:" in line for line in outcome) or not any(
        line.startswith(("ok:", "changed:")) for line in outcome
    ):
        raise SystemExit(1)
PY
}

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
copy_repo_to_guest "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519"

if [[ "${DO_BOOTSTRAP_TIMEOUT}" == "true" ]]; then
    echo "[E2E] Injecting a bounded pre-setup wg-easy startup timeout..."
    run_remote "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
        "python3 -c \"from pathlib import Path; path=Path('/tmp/ztrepo/roles/vps_orchestration/templates/docker-compose.yml.j2'); marker='    container_name: wg-easy\\n'; data=path.read_text(); count=data.count(marker); count == 1 or (_ for _ in ()).throw(RuntimeError('unexpected wg-easy service count')); path.write_text(data.replace(marker, marker + '    entrypoint: [\\\"sleep\\\", \\\"300\\\"]\\n'))\" && grep -q 'entrypoint: \[\"sleep\", \"300\"\]' /tmp/ztrepo/roles/vps_orchestration/templates/docker-compose.yml.j2 && cd /tmp/ztrepo && git add roles/vps_orchestration/templates/docker-compose.yml.j2 && git -c user.name=e2e -c user.email=e2e.invalid commit --amend --no-edit -q"
fi

# --- run the public installer (non-interactive) ------------------------------
echo "[E2E] Running the public installer non-interactively (repo=/tmp/ztrepo, ref=${INSTALL_REF})"
if [[ "${DO_BOOTSTRAP_TIMEOUT}" == "true" ]]; then
    bootstrap_failure_started="${SECONDS}"
    bootstrap_failure_log="${TMP_DIR}/bootstrap-failure.log"
    if run_public_installer "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" | \
        tee "${bootstrap_failure_log}"; then
        fail "injected wg-easy authentication timeout unexpectedly succeeded"
    fi
    bootstrap_failure_elapsed=$((SECONDS - bootstrap_failure_started))
    [[ "${bootstrap_failure_elapsed}" -ge 80 && "${bootstrap_failure_elapsed}" -le 1800 ]] || \
        fail "injected wg-easy authentication failure was not bounded"
    if grep -q "credential cleanup could not be verified" "${bootstrap_failure_log}"; then
        fail "safe upstream INIT default was rejected during cleanup"
    fi
    grep -q "secret state was scrubbed and setup remains retryable" \
        "${bootstrap_failure_log}" || fail "redacted retryable cleanup failure was not reported"
    require_ssh_ready "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 60
    verify_bootstrap_secret_free \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    verify_bootstrap_state \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" incomplete
    echo "[E2E] Injected bootstrap failure was nonzero, bounded, secret-free, and incomplete"

    echo "[E2E] Restoring the production role and retrying normally..."
    copy_repo_to_guest \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    bootstrap_retry_log="${TMP_DIR}/bootstrap-retry.log"
    run_public_installer \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" | \
        tee "${bootstrap_retry_log}"
    verify_bootstrap_auth_tasks_ran "${bootstrap_retry_log}"
    verify_bootstrap_state \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" complete
    echo "[E2E] Same-VM retry executed both authentication phases to durable completion"
else
    run_public_installer "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519"
fi

echo "[E2E] Verifying the deployed stack on the hardened SSH port ${QEMU_ADMIN_PORT}"
export E2E_SSH_PORT E2E_WG_PORT
verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
verify_wg_login "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
verify_bootstrap_secret_free \
    "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
echo "[E2E] wg-easy login and secret scrub verified"

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
    wg_container_id_before="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect wg-easy --format "{{.Id}}"')"
    echo "[E2E] Re-copying the repository into the guest (the reboot clears /tmp)..."
    copy_repo_to_guest \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Re-running the installer to verify idempotency..."
    run_public_installer \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Verifying the stack after the second installer run..."
    verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    wg_container_id_after="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect wg-easy --format "{{.Id}}"')"
    [[ "${wg_container_id_after}" == "${wg_container_id_before}" ]] || \
        fail "completed wg-easy setup was recreated"
    verify_wg_login "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    verify_bootstrap_secret_free \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Completed rerun preserved wg-easy identity and credentials"

    echo "[E2E] Exercising retry from a nonzero setup_step..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo docker stop wg-easy >/dev/null && sudo python3 -c \"import sqlite3; db=sqlite3.connect('/opt/zero-trust-vps/volumes/wg-easy/wg-easy.db'); db.execute('DELETE FROM users_table'); db.execute('UPDATE general_table SET setup_step=2'); db.commit(); db.close()\""
    run_public_installer \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo python3 -c \"import sqlite3; db=sqlite3.connect('/opt/zero-trust-vps/volumes/wg-easy/wg-easy.db'); rows=db.execute('SELECT setup_step FROM general_table').fetchall(); db.close(); raise SystemExit(0 if rows == [(0,)] else 1)\""
    verify_wg_login "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    verify_bootstrap_secret_free \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Nonzero setup state retried to durable completion"
fi

echo "[E2E] PASS: public installer E2E succeeded in qemu/KVM"
