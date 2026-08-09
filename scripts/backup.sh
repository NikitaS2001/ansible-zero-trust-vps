#!/usr/bin/env bash
# Backup the zero-trust stack. Run on the VPS as root.
#
# Usage:
#   sudo scripts/backup.sh [/path/to/backup.tgz]      # run from the repo dir
#
# Behavior:
#   - stops the containers so the wg-easy SQLite DB and AdGuard state are
#     quiescent (the VPN blips for the seconds the tar takes)
#   - archives the project root: volumes/*, docker-compose.yml,
#     docker-compose.override.yml, Caddyfile, Caddyfile.d
#   - encrypts the archive with age when AGE_KEY (a public key) is set;
#     otherwise writes a plaintext archive and warns
#   - rotates old backups, keeping ZERO_TRUST_KEEP_BACKUPS (default 14)
#
# Encrypted-restore companion: scripts/restore.sh. For very large/heavy
# datasets consider restic (documented in README) instead of tar.
set -euo pipefail

PROJECT_ROOT="${ZERO_TRUST_PROJECT_ROOT:-/opt/zero-trust-vps}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-/opt/zt-backups/zt-${STAMP}.tar.gz}"
KEEP="${ZERO_TRUST_KEEP_BACKUPS:-14}"

TMP_DIR="$(mktemp -d /tmp/zt-backup.XXXXXX)"
TAR_FILE="${TMP_DIR}/backup.tar.gz"
cleanup() {
    COMPOSE_ARGS=(-f "${PROJECT_ROOT}/docker-compose.yml")
    [[ -f "${PROJECT_ROOT}/docker-compose.override.yml" ]] \
        && COMPOSE_ARGS+=(-f "${PROJECT_ROOT}/docker-compose.override.yml")
    docker compose "${COMPOSE_ARGS[@]}" up -d --no-recreate 2>/dev/null || true
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

[[ -d "${PROJECT_ROOT}/volumes" ]] || { echo "[FAIL] ${PROJECT_ROOT}/volumes not found" >&2; exit 1; }
mkdir -p "$(dirname "${OUT}")"

# Stop/start the whole project, including any docker-compose.override.yml
# user services, so the snapshot is consistent.
COMPOSE_ARGS=(-f "${PROJECT_ROOT}/docker-compose.yml")
[[ -f "${PROJECT_ROOT}/docker-compose.override.yml" ]] \
    && COMPOSE_ARGS+=(-f "${PROJECT_ROOT}/docker-compose.override.yml")

echo "[1/4] Stopping containers for a consistent snapshot..."
docker compose "${COMPOSE_ARGS[@]}" stop

echo "[2/4] Archiving the project runtime state..."
TAR_ARGS=(-C "$(dirname "${PROJECT_ROOT}")")
BASE="$(basename "${PROJECT_ROOT}")"
for member in "volumes" "docker-compose.yml" "Caddyfile" "Caddyfile.d" "docker-compose.override.yml"; do
    [[ -e "${PROJECT_ROOT}/${member}" ]] && TAR_ARGS+=("${BASE}/${member}")
done
tar -czf "${TAR_FILE}" "${TAR_ARGS[@]}"

if [[ -n "${AGE_KEY:-}" ]]; then
    command -v age >/dev/null || { echo "[FAIL] AGE_KEY is set but 'age' is not installed" >&2; exit 1; }
    echo "[3/4] Encrypting with age..."
    age -r "${AGE_KEY}" -o "${OUT}" "${TAR_FILE}"
else
    echo "[3/4] No AGE_KEY set; keeping the archive PLAINTEXT. Export AGE_KEY to encrypt." >&2
    mv "${TAR_FILE}" "${OUT}"
fi

echo "[4/4] Rotating old backups (keeping ${KEEP})..."
if [[ -d /opt/zt-backups ]]; then
    find /opt/zt-backups -maxdepth 1 -type f -name 'zt-*.tar.gz*' -print0 \
        | sort -zr \
        | tail -n +$((KEEP + 1)) -z \
        | xargs -0 -r rm -f
fi

echo "[OK] Backup written to ${OUT} ($(du -h "${OUT}" | cut -f1))"
