#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${1:-} == --help ]]; then
    echo 'Usage: restore-drill.sh [user@host] [ssh-port] [ssh-key]'
    exit 0
fi
[[ $# -le 3 ]] || { echo '[FAIL] too many arguments' >&2; exit 2; }

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${E2E_DIR}/../.." && pwd)"
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

TARGET="${1:-sysadmin@127.0.0.1}"
PORT="${2:-${QEMU_ADMIN_PORT:-2255}}"
KEY="${3:-${TMP_DIR:-/tmp}/id_ed25519}"
REMOTE_WORK="${RESTORE_DRILL_REMOTE_WORK:-/var/tmp/zt-restore-drill}"
REMOTE_PROJECT_ROOT="${RESTORE_DRILL_PROJECT_ROOT:-/opt/zero-trust-vps}"
DRILL_TIMEOUT="${RESTORE_DRILL_TIMEOUT:-600}"
[[ ${REMOTE_WORK} =~ ^/var/tmp/zt-restore-drill([.][A-Za-z0-9_-]+)?$ ]] \
    || { echo '[FAIL] unsafe remote work path' >&2; exit 2; }
[[ ${REMOTE_PROJECT_ROOT} =~ ^/[A-Za-z0-9._/-]+$ \
    && ${REMOTE_PROJECT_ROOT} != / && ${REMOTE_PROJECT_ROOT} != *'/../'* ]] \
    || { echo '[FAIL] unsafe remote project root' >&2; exit 2; }
[[ ${DRILL_TIMEOUT} =~ ^[1-9][0-9]*$ ]] \
    || { echo '[FAIL] restore drill timeout must be a positive integer' >&2; exit 2; }

cleanup_remote() {
    trap - EXIT
    run_remote "${TARGET}" "${PORT}" "${KEY}" \
        "sudo rm -rf -- '${REMOTE_WORK}'" >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT

run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "sudo install -d -m 0700 '${REMOTE_WORK}'"
run_remote_stdin "${TARGET}" "${PORT}" "${KEY}" \
    "sudo tee '${REMOTE_WORK}/backup.sh' >/dev/null && sudo chmod 0755 '${REMOTE_WORK}/backup.sh'" \
    <"${ROOT_DIR}/scripts/backup.sh"
run_remote_stdin "${TARGET}" "${PORT}" "${KEY}" \
    "sudo tee '${REMOTE_WORK}/restore.sh' >/dev/null && sudo chmod 0755 '${REMOTE_WORK}/restore.sh'" \
    <"${ROOT_DIR}/scripts/restore.sh"
BACKUP_SHA="$(sha256sum "${ROOT_DIR}/scripts/backup.sh" | cut -d' ' -f1)"
RESTORE_SHA="$(sha256sum "${ROOT_DIR}/scripts/restore.sh" | cut -d' ' -f1)"
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "printf '%s  %s\\n' '${BACKUP_SHA}' '${REMOTE_WORK}/backup.sh' '${RESTORE_SHA}' '${REMOTE_WORK}/restore.sh' | sudo sha256sum -c - >/dev/null"

run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "sudo timeout --signal=TERM --kill-after=30s '${DRILL_TIMEOUT}s' env DRILL_PROJECT_ROOT='${REMOTE_PROJECT_ROOT}' DRILL_WORK='${REMOTE_WORK}' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
step=preflight
trap 'echo "[FAIL] restore drill remote step=${step}" >&2' ERR
project="${DRILL_PROJECT_ROOT}"
work="${DRILL_WORK}"
db="${project}/volumes/wg-easy/wg-easy.db"
ca="${project}/volumes/caddy/data/caddy/pki/authorities/local/root.crt"
override="${project}/docker-compose.override.yml"
command -v age >/dev/null
command -v age-keygen >/dev/null
test -f "${db}"
test -f "${ca}"
test -f "${override}"
db_before="$(sha256sum "${db}" | cut -d' ' -f1)"
ca_before="$(sha256sum "${ca}" | cut -d' ' -f1)"
override_before="$(sha256sum "${override}" | cut -d' ' -f1)"
step=backup
age-keygen -o "${work}/identity" >/dev/null 2>&1
chmod 0600 "${work}/identity"
recipient="$(age-keygen -y "${work}/identity")"
env AGE_KEY="${recipient}" ZERO_TRUST_PROJECT_ROOT="${project}" \
    "${work}/backup.sh" "${work}/backup.tar.gz" >/dev/null
archive="${work}/backup.tar.gz.age"
test -s "${archive}"
test "$(stat -c %a "${archive}")" = 600
head -c 18 "${archive}" | grep -q '^age-encryption.org'
step=destructive-mutation
docker compose -f "${project}/docker-compose.yml" \
    -f "${override}" stop >/dev/null
rm -f -- "${db}" "${ca}" "${override}"
step=restore
if ! env ZERO_TRUST_PROJECT_ROOT="${project}" \
    "${work}/restore.sh" "${archive}" "${work}/identity" \
    >"${work}/restore.out" 2>"${work}/restore.err"; then
    sed -n '1,20p' "${work}/restore.out" >&2
    sed -n '1,20p' "${work}/restore.err" >&2
    exit 1
fi
step=verification
test "$(sha256sum "${db}" | cut -d' ' -f1)" = "${db_before}"
test "$(sha256sum "${ca}" | cut -d' ' -f1)" = "${ca_before}"
test "$(sha256sum "${override}" | cut -d' ' -f1)" = "${override_before}"
docker compose -f "${project}/docker-compose.yml" -f "${override}" config -q
docker exec wg-easy wg show >/dev/null
step=complete
REMOTE

echo '[E2E] PASS: encrypted destructive backup/restore recovered DB, Caddy CA, and override'
