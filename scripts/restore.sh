#!/usr/bin/env bash
# Restore a backup produced by scripts/backup.sh. Run on the VPS as root.
#
# Usage:
#   sudo scripts/restore.sh /path/to/backup.tgz [age-identity.txt]
#
# Stops the stack, restores the project runtime state (volumes + compose +
# Caddy config), recreates the containers, and leaves the environment ready
# for a playbook re-run and verification.
set -euo pipefail

PROJECT_ROOT="${ZERO_TRUST_PROJECT_ROOT:-/opt/zero-trust-vps}"
BACKUP="${1:?usage: restore.sh <backup.tgz> [age-identity.txt]}"
AGE_KEY="${2:-${ZERO_TRUST_AGE_KEY:-}}"

[[ -f "${BACKUP}" ]] || { echo "[FAIL] backup not found: ${BACKUP}" >&2; exit 1; }

TMP_DIR="$(mktemp -d /tmp/zt-restore.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

TAR=""
# Detect age-encrypted archives by magic, not just by the .age suffix, so a
# misnamed (or legacy .tar.gz) encrypted backup is still restored correctly.
if head -c 18 "${BACKUP}" | grep -q '^age-encryption.org'; then
    command -v age >/dev/null || { echo "[FAIL] 'age' is not installed" >&2; exit 1; }
    [[ -n "${AGE_KEY}" ]] || { echo "[FAIL] encrypted backup requires an age identity file" >&2; exit 1; }
    TAR="${TMP_DIR}/backup.tar.gz"
    age -d -i "${AGE_KEY}" -o "${TAR}" "${BACKUP}"
else
    TAR="${BACKUP}"
fi

echo "[1/4] Stopping the stack before restore..."
COMPOSE_ARGS=(-f "${PROJECT_ROOT}/docker-compose.yml")
[[ -f "${PROJECT_ROOT}/docker-compose.override.yml" ]] \
    && COMPOSE_ARGS+=(-f "${PROJECT_ROOT}/docker-compose.override.yml")
docker compose "${COMPOSE_ARGS[@]}" stop 2>/dev/null || true

echo "[2/4] Restoring the project runtime state..."
tar -xzf "${TAR}" -C "$(dirname "${PROJECT_ROOT}")"

echo "[3/4] Recreating containers with the restored volumes..."
docker compose "${COMPOSE_ARGS[@]}" up -d

echo "[4/4] Finished."
echo "[OK] Restored from ${BACKUP}. Re-run the playbook to re-render managed"
echo "     configs, then scripts/synthetic-check.sh (or the e2e suite) to verify."
