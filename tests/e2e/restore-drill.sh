#!/usr/bin/env bash
# E2E backup/restore drill against a running VPS/VM (e.g. the qemu VM left by
# qemu-install.sh). Destroys the wg-easy database, restores it from a backup,
# and verifies the stack comes back.
#
# Usage (right after qemu-install.sh in the same shell):
#   bash tests/e2e/restore-drill.sh
# Or explicitly:
#   bash tests/e2e/restore-drill.sh <user@host> <ssh-port> <ssh-key>
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

TARGET="${1:-sysadmin@127.0.0.1}"
PORT="${2:-${QEMU_ADMIN_PORT:-2255}}"
KEY="${3:-${TMP_DIR:-/tmp}/id_ed25519}"

run_remote_stdin "${TARGET}" "${PORT}" "${KEY}" 'sudo bash -s > /tmp/backup.sh' < scripts/backup.sh
run_remote_stdin "${TARGET}" "${PORT}" "${KEY}" 'sudo bash -s > /tmp/restore.sh' < scripts/restore.sh

echo "[E2E] Taking a backup (plaintext, no AGE_KEY)..."
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    'sudo bash /tmp/backup.sh /tmp/zt-backup.tgz'

echo "[E2E] Verifying the backup contains the wg-easy database..."
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    'tar -tzf /tmp/zt-backup.tgz | grep -q volumes/wg-easy/wg-easy.db'

echo "[E2E] Destroying the wg-easy database..."
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    'sudo docker compose -f /opt/zero-trust-vps/docker-compose.yml stop >/dev/null && sudo rm -f /opt/zero-trust-vps/volumes/wg-easy/wg-easy.db'

echo "[E2E] Restoring from the backup..."
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    'sudo bash /tmp/restore.sh /tmp/zt-backup.tgz'

echo "[E2E] Verifying the restored stack..."
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    'test -f /opt/zero-trust-vps/volumes/wg-easy/wg-easy.db'
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    'sudo docker exec wg-easy wg show >/dev/null'

echo "[E2E] PASS: backup/restore drill succeeded"
