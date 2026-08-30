#!/usr/bin/env bash
# Disposable single-guest lifecycle test:
#   immutable v1.2.1 -> current working tree -> no-change rerun -> restore drill.
#
# The source repository presented to the guest contains the original signed
# v1.2.1 tag plus a synthetic current branch built from the exact working tree.
set -euo pipefail
umask 077

if [[ ${1:-} == --help ]]; then
    cat <<'EOF'
Usage: tests/e2e/lifecycle-qemu.sh

Environment:
  QEMU_IMAGE        cloud image URL/path (Ubuntu 24.04 by default)
  QEMU_USER         initial cloud image user (ubuntu by default)
  QEMU_SSH_PORT     host port forwarded to guest:22 (default 2263)
  QEMU_ADMIN_PORT   host port forwarded to hardened SSH (default 2262)
  QEMU_WG_PORT      host UDP port forwarded to WireGuard (default 51863)
  E2E_ARTIFACT_DIR  persistent log directory
                    (default: ${TMPDIR:-/tmp}/ztvps-lifecycle-evidence.UTC)
  E2E_SOURCE_FIXTURE_ONLY=1  validate the dual-ref source fixture without a VM
EOF
    exit 0
fi
[[ $# -eq 0 ]] || { echo '[FAIL] lifecycle-qemu.sh accepts no arguments' >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_DIR="${ROOT_DIR}/tests/e2e"
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

DEFAULT_IMAGE='https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img'
QEMU_IMAGE="${QEMU_IMAGE:-${DEFAULT_IMAGE}}"
QEMU_USER="${QEMU_USER:-ubuntu}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2263}"
QEMU_ADMIN_PORT="${QEMU_ADMIN_PORT:-2262}"
QEMU_WG_PORT="${QEMU_WG_PORT:-51863}"
CURRENT_REF=e2e-current
ARTIFACT_DIR="${E2E_ARTIFACT_DIR:-${TMPDIR:-/tmp}/ztvps-lifecycle-evidence.$(date -u +%Y%m%dT%H%M%SZ)}"
SOURCE_FIXTURE_ONLY="${E2E_SOURCE_FIXTURE_ONLY:-0}"
EXPECTED_BASELINE_TAG_OBJECT=689458a7bbbb73e7c4796612ca5e5215452cb386
EXPECTED_BASELINE_COMMIT=8d650df376743897f0970f460e3ae8fccf340571

[[ ${SOURCE_FIXTURE_ONLY} =~ ^[01]$ ]] \
    || fail 'E2E_SOURCE_FIXTURE_ONLY must be 0 or 1'

for tool in ssh-keygen openssl git tar sha256sum; do
    command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done
if [[ ${SOURCE_FIXTURE_ONLY} == 0 ]]; then
    for tool in qemu-system-x86_64 qemu-img genisoimage curl ssh; do
        command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
    done
    [[ -e /dev/kvm ]] || fail '/dev/kvm is required for the disposable lifecycle test'
fi

install -d -m 0700 "${ARTIFACT_DIR}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-lifecycle.XXXXXX")"
STATE_SENTINEL="${TMP_DIR}/.lifecycle-state"
printf 'ztvps-lifecycle-v1\n' >"${STATE_SENTINEL}"
QEMU_PID=''
cleanup() {
    local rc=$? cleanup_ok=true
    trap - EXIT
    if [[ -n ${QEMU_PID} ]] && kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
        for _ in {1..10}; do
            kill -0 "${QEMU_PID}" >/dev/null 2>&1 || break
            sleep 1
        done
        if kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
            kill -9 "${QEMU_PID}" >/dev/null 2>&1 || true
            cleanup_ok=false
        fi
    fi
    if [[ ! -f ${STATE_SENTINEL} || $(<"${STATE_SENTINEL}") != ztvps-lifecycle-v1 ]]; then
        echo '[CLEANUP] refusing to remove unrecognized lifecycle state' >&2
        cleanup_ok=false
    elif ! rm -rf -- "${TMP_DIR}" || [[ -e ${TMP_DIR} ]]; then
        cleanup_ok=false
    fi
    if [[ ${cleanup_ok} == true ]]; then
        echo 'cleanup.qemu_stopped=PASS' | tee -a "${ARTIFACT_DIR}/cleanup.log"
        echo 'cleanup.ephemeral_state_removed=PASS' | tee -a "${ARTIFACT_DIR}/cleanup.log"
    else
        echo 'cleanup.complete=FAIL' | tee -a "${ARTIFACT_DIR}/cleanup.log" >&2
        rc=1
    fi
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ssh-keygen -q -t ed25519 -N '' -f "${TMP_DIR}/id_ed25519" -C e2e-lifecycle
PUBKEY="$(<"${TMP_DIR}/id_ed25519.pub")"
ADMIN_PASS="$(openssl rand -hex 12)"
ADGUARD_PASS="$(openssl rand -hex 12)"
WG_PASS="${ZERO_TRUST_WG_PASSWORD:-Twelve\$LIFECYCLE_PROBE}"

echo '[E2E] Building a guest-local origin with the immutable baseline and exact working tree...'
[[ $(git -C "${ROOT_DIR}" cat-file -t refs/tags/v1.2.1) == tag ]] \
    || fail 'v1.2.1 must be an annotated tag'
BASELINE_SHA="$(git -C "${ROOT_DIR}" rev-parse 'v1.2.1^{commit}')"
[[ $(git -C "${ROOT_DIR}" rev-parse refs/tags/v1.2.1) == "${EXPECTED_BASELINE_TAG_OBJECT}" \
    && ${BASELINE_SHA} == "${EXPECTED_BASELINE_COMMIT}" ]] \
    || fail 'local v1.2.1 does not match the immutable release identity'
git clone --quiet --bare "${ROOT_DIR}" "${TMP_DIR}/origin.git"
install -d -m 0700 "${TMP_DIR}/current-tree"
while IFS= read -r -d '' path; do
    if [[ -e ${ROOT_DIR}/${path} || -L ${ROOT_DIR}/${path} ]]; then
        printf '%s\0' "${path}"
    fi
done < <(git -C "${ROOT_DIR}" ls-files -z --cached --others --exclude-standard) \
    | tar --null -cf - -C "${ROOT_DIR}" --files-from - \
    | tar -xf - -C "${TMP_DIR}/current-tree"
git -C "${TMP_DIR}/current-tree" init -q -b "${CURRENT_REF}"
git -C "${TMP_DIR}/current-tree" add -A
git -C "${TMP_DIR}/current-tree" -c user.name=e2e -c user.email=e2e.invalid \
    commit -qm 'exact lifecycle working tree'
CURRENT_SHA="$(git -C "${TMP_DIR}/current-tree" rev-parse HEAD)"
git -C "${TMP_DIR}/current-tree" remote add origin "${TMP_DIR}/origin.git"
git -C "${TMP_DIR}/current-tree" push -q origin "${CURRENT_REF}"
printf 'baseline_ref=v1.2.1\nbaseline_sha=%s\ncurrent_ref=%s\ncurrent_sha=%s\n' \
    "${BASELINE_SHA}" "${CURRENT_REF}" "${CURRENT_SHA}" \
    >"${ARTIFACT_DIR}/source-provenance.txt"
git --git-dir="${TMP_DIR}/origin.git" ls-tree -r --full-tree "${CURRENT_SHA}" \
    >"${ARTIFACT_DIR}/source-manifest.txt"
[[ $(git --git-dir="${TMP_DIR}/origin.git" rev-parse 'v1.2.1^{commit}') == "${BASELINE_SHA}" ]]
[[ $(git --git-dir="${TMP_DIR}/origin.git" rev-parse "${CURRENT_REF}^{commit}") == "${CURRENT_SHA}" ]]
[[ $(git --git-dir="${TMP_DIR}/origin.git" show "${CURRENT_REF}:install.sh" | sha256sum | cut -d' ' -f1) \
    == "$(sha256sum "${ROOT_DIR}/install.sh" | cut -d' ' -f1)" ]]
echo 'predicate.dual_ref_source_fixture=PASS' | tee -a "${ARTIFACT_DIR}/predicates.log"
if [[ ${SOURCE_FIXTURE_ONLY} == 1 ]]; then
    sha256sum "${ARTIFACT_DIR}/predicates.log" "${ARTIFACT_DIR}"/*.txt \
        >"${ARTIFACT_DIR}/SHA256SUMS"
    echo "[E2E] PASS: source fixture evidence recorded in ${ARTIFACT_DIR}"
    exit 0
fi

boot_vm "${TMP_DIR}" "${QEMU_IMAGE}" 20 2048 2 ztvps-lifecycle \
    ztvps-lifecycle '' \
    "hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22" \
    "hostfwd=tcp:127.0.0.1:${QEMU_ADMIN_PORT}-:${E2E_SSH_PORT}" \
    "hostfwd=udp:127.0.0.1:${QEMU_WG_PORT}-:${E2E_WG_PORT}"

GUEST="${QEMU_USER}@127.0.0.1"
require_ssh_ready "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" 60
E2E_KNOWN_HOSTS="${TMP_DIR}/known_hosts"
: >"${E2E_KNOWN_HOSTS}"
chmod 0600 "${E2E_KNOWN_HOSTS}"
record_ssh_host_key 127.0.0.1 "${QEMU_SSH_PORT}" "${E2E_KNOWN_HOSTS}"
export E2E_KNOWN_HOSTS E2E_SSH_PORT E2E_WG_PORT

tar -czf - -C "${TMP_DIR}" origin.git | \
    run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo tar -xzf - -C /var/tmp && sudo chown -R root:root /var/tmp/origin.git && sudo chmod -R go-rwx /var/tmp/origin.git'
run_remote "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo sh -eu -c \"git --git-dir=/var/tmp/origin.git show v1.2.1:install.sh > /var/tmp/zt-v1.2.1-install.sh && git --git-dir=/var/tmp/origin.git show '${CURRENT_REF}':install.sh > /var/tmp/zt-current-install.sh && chmod 0700 /var/tmp/zt-v1.2.1-install.sh /var/tmp/zt-current-install.sh\""

printf -v q_admin '%q' "${ADMIN_PASS}"
printf -v q_adguard '%q' "${ADGUARD_PASS}"
printf -v q_wg '%q' "${WG_PASS}"
printf -v q_pubkey '%q' "${PUBKEY}"
installer_environment="ZERO_TRUST_NONINTERACTIVE=1 ZERO_TRUST_REPO_URL=file:///var/tmp/origin.git \
ZERO_TRUST_SSH_PORT=${E2E_SSH_PORT} ZERO_TRUST_WG_PORT=${E2E_WG_PORT} \
ZERO_TRUST_ADMIN_USER=sysadmin ZERO_TRUST_ADMIN_PASSWORD=${q_admin} \
ZERO_TRUST_ADGUARD_PASSWORD=${q_adguard} ZERO_TRUST_WG_PASSWORD=${q_wg} \
ZERO_TRUST_INTERNAL_DOMAIN_SUFFIX=internal \
ZERO_TRUST_INTERNAL_DOMAINS='wg.internal adguard.internal' \
ZERO_TRUST_SSH_PUBKEY=${q_pubkey} ZERO_TRUST_WG_HOST=127.0.0.1"

TARGET='sysadmin@127.0.0.1'

run_baseline_install() {
    local log_file=$1
    local target=$2
    local ssh_port=$3
    run_remote "${target}" "${ssh_port}" "${TMP_DIR}/id_ed25519" \
        "sudo env ${installer_environment} ZERO_TRUST_RELEASE_REF=v1.2.1 bash /var/tmp/zt-v1.2.1-install.sh" \
        2>&1 | tee "${log_file}"
}

connect_as_admin() {
    record_ssh_host_key 127.0.0.1 "${QEMU_ADMIN_PORT}" "${E2E_KNOWN_HOSTS}"
    require_ssh_ready "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 60
}

# v1.2.1 validates Caddy through a mutable Docker tag without retrying its
# image pull. Retry its unchanged installer once so transient registry failures
# do not invalidate the upgrade lifecycle contract.
echo '[E2E] Installing immutable v1.2.1 baseline...'
if ! run_baseline_install "${ARTIFACT_DIR}/baseline-install.log" \
    "${GUEST}" "${QEMU_SSH_PORT}"; then
    echo '[E2E] Retrying immutable v1.2.1 baseline after validation failure...'
    connect_as_admin
    run_baseline_install "${ARTIFACT_DIR}/baseline-install-retry.log" \
        "${TARGET}" "${QEMU_ADMIN_PORT}"
fi
connect_as_admin
deployed_baseline="$(run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    'sudo git -C /opt/zero-trust-vps-installer/repo rev-parse HEAD')"
[[ ${deployed_baseline} == "${BASELINE_SHA}" ]] || fail 'guest baseline does not match v1.2.1'
baseline_wg_identity="$(run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo python3 -c \"import json,sqlite3; db=sqlite3.connect('/opt/zero-trust-vps/volumes/wg-easy/wg-easy.db'); value={'setup_step':db.execute('SELECT setup_step FROM general_table').fetchall(),'users':db.execute('SELECT * FROM users_table ORDER BY id').fetchall()}; db.close(); print(json.dumps(value,sort_keys=True,separators=(',',':')))\"")"
baseline_ca="$(run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo sha256sum /opt/zero-trust-vps/volumes/caddy/data/caddy/pki/authorities/local/root.crt | cut -d' ' -f1")"
echo 'predicate.baseline_exact_tag=PASS' | tee -a "${ARTIFACT_DIR}/predicates.log"

echo '[E2E] Upgrading the same guest to the exact current working tree...'
run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo env ZERO_TRUST_DEV_MODE=1 ${installer_environment} ZERO_TRUST_RELEASE_REF=${CURRENT_REF} bash /var/tmp/zt-current-install.sh" \
    2>&1 | tee "${ARTIFACT_DIR}/upgrade.log"
deployed_current="$(run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    'sudo git -C /opt/zero-trust-vps-installer/repo rev-parse HEAD')"
[[ ${deployed_current} == "${CURRENT_SHA}" ]] || fail 'guest upgrade does not match current synthetic commit'
[[ $(run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo python3 -c \"import json,sqlite3; db=sqlite3.connect('/opt/zero-trust-vps/volumes/wg-easy/wg-easy.db'); value={'setup_step':db.execute('SELECT setup_step FROM general_table').fetchall(),'users':db.execute('SELECT * FROM users_table ORDER BY id').fetchall()}; db.close(); print(json.dumps(value,sort_keys=True,separators=(',',':')))\"") == "${baseline_wg_identity}" ]] \
    || fail 'upgrade changed wg-easy setup or administrator identity'
[[ $(run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo sha256sum /opt/zero-trust-vps/volumes/caddy/data/caddy/pki/authorities/local/root.crt | cut -d' ' -f1") == "${baseline_ca}" ]] \
    || fail 'upgrade changed the Caddy CA identity'
verify_deployment "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
echo 'predicate.upgrade_preserved_wg_identity_and_ca=PASS' | tee -a "${ARTIFACT_DIR}/predicates.log"

echo '[E2E] Proving host netfilter readiness and services-only WireGuard policy...'
run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    'sudo bash -se' 2>&1 <<'REMOTE' | tee "${ARTIFACT_DIR}/post-upgrade-network.log"
set -euo pipefail

echo '## host kernel and loaded netfilter modules'
uname -r
for module in \
    iptable_filter ip6table_filter iptable_nat ip6table_nat \
    xt_MASQUERADE xt_comment xt_tcpudp; do
    grep -E "^${module}[[:space:]]" /proc/modules
    grep -Rxs -- "${module}" /etc/modules /etc/modules-load.d >/dev/null
    printf 'module.%s.loaded_and_persistent=PASS\n' "${module}"
done

echo '## explicit WireGuard interface'
docker exec wg-easy wg show wg0
docker exec wg-easy ip link show wg0

echo '## IPv4 filter table'
docker exec wg-easy iptables-save -t filter
docker exec wg-easy iptables -C FORWARD -i wg0 -j WG_CLIENTS
test "$(docker exec wg-easy iptables -S WG_CLIENTS | tail -n 1)" = '-A WG_CLIENTS -j DROP'

echo '## IPv6 filter table'
docker exec wg-easy ip6tables-save -t filter
docker exec wg-easy ip6tables -C FORWARD -i wg0 -j WG_CLIENTS
test "$(docker exec wg-easy ip6tables -S WG_CLIENTS | tail -n 1)" = '-A WG_CLIENTS -j DROP'

echo 'predicate.host_netfilter_modules_loaded_and_persistent=PASS'
echo 'predicate.wg0_explicitly_present=PASS'
echo 'predicate.services_only_v4_v6_hooks_and_terminal_drop=PASS'
REMOTE
echo 'predicate.post_upgrade_network_contract=PASS' | tee -a "${ARTIFACT_DIR}/predicates.log"

"${E2E_DIR}/idempotency-rerun.sh" "${TARGET}" "${QEMU_ADMIN_PORT}" \
    "${TMP_DIR}/id_ed25519" file:///var/tmp/origin.git "${CURRENT_REF}" \
    2>&1 | tee "${ARTIFACT_DIR}/idempotency.log"

"${E2E_DIR}/restore-drill.sh" "${TARGET}" "${QEMU_ADMIN_PORT}" \
    "${TMP_DIR}/id_ed25519" 2>&1 | tee "${ARTIFACT_DIR}/restore.log"
run_remote "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
    'sudo bash -se' 2>&1 <<'REMOTE' | tee "${ARTIFACT_DIR}/post-restore-readiness.log"
set -euo pipefail
for attempt in $(seq 1 30); do
    state="$(docker inspect --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' wg-easy adguard caddy)"
    if grep -Eq '^/wg-easy running (none|healthy)$' <<<"${state}" \
        && grep -q '^/adguard running healthy$' <<<"${state}" \
        && grep -q '^/caddy running healthy$' <<<"${state}"; then
        printf '%s\n' "${state}"
        echo 'predicate.post_restore_stack_ready=PASS'
        exit 0
    fi
    sleep 2
done
printf '%s\n' "${state}" >&2
exit 1
REMOTE
verify_deployment "${TARGET}" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
echo 'predicate.restore_recovered_current_stack=PASS' | tee -a "${ARTIFACT_DIR}/predicates.log"

sha256sum "${ARTIFACT_DIR}"/*.log "${ARTIFACT_DIR}"/*.txt \
    >"${ARTIFACT_DIR}/SHA256SUMS"
echo "[E2E] PASS: lifecycle evidence recorded in ${ARTIFACT_DIR}"
