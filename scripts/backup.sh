#!/usr/bin/env bash
# Backup the zero-trust stack. Run on the VPS as root.
#
# Usage:
#   sudo env AGE_KEY="age1..." scripts/backup.sh [/path/to/backup.tar.gz]
#   sudo scripts/backup.sh --allow-plaintext [/path/to/backup.tar.gz]
#
# Behavior:
#   - stops the containers so the wg-easy SQLite DB and AdGuard state are
#     quiescent (the VPN blips for the seconds the tar takes)
#   - archives the project root: volumes/*, docker-compose.yml,
#     docker-compose.override.yml, Caddyfile, Caddyfile.d
#   - encrypts the archive with age by default; plaintext requires the explicit
#     --allow-plaintext escape hatch
#   - rotates old backups, keeping ZERO_TRUST_KEEP_BACKUPS (default 14)
#
# Encrypted-restore companion: scripts/restore.sh. For very large/heavy
# datasets consider restic (documented in README) instead of tar.
set -euo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage: backup.sh [--allow-plaintext] [output-base.tar.gz]

Backups are age-encrypted by default and require AGE_KEY. Use
--allow-plaintext explicitly to publish an unencrypted private archive.
EOF
}

ALLOW_PLAINTEXT=false
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --allow-plaintext) ALLOW_PLAINTEXT=true; shift ;;
    -*) echo "[FAIL] unknown option: $1" >&2; usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "[FAIL] too many arguments" >&2; usage >&2; exit 2; }
[[ ${1:-} != --* ]] || { echo "[FAIL] options must precede the output path" >&2; usage >&2; exit 2; }

if [[ ${ALLOW_PLAINTEXT} == false && -z ${AGE_KEY:-} ]]; then
    echo "[FAIL] AGE_KEY is required unless --allow-plaintext is used" >&2
    exit 1
fi
if [[ ${ALLOW_PLAINTEXT} == false ]] && ! command -v age >/dev/null; then
    echo "[FAIL] encrypted backup requires 'age'" >&2
    exit 1
fi

PROJECT_ROOT="${ZERO_TRUST_PROJECT_ROOT:-/opt/zero-trust-vps}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-/opt/zt-backups/zt-${STAMP}.tar.gz}"
KEEP="${ZERO_TRUST_KEEP_BACKUPS:-14}"

COMPOSE_ARGS=(-f "${PROJECT_ROOT}/docker-compose.yml")
[[ -f "${PROJECT_ROOT}/docker-compose.override.yml" ]] \
    && COMPOSE_ARGS+=(-f "${PROJECT_ROOT}/docker-compose.override.yml")
STOPPED=false
TAR_FILE=
PUBLISH_TMP=
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ ${STOPPED} == true ]]; then
        if ! docker compose "${COMPOSE_ARGS[@]}" up -d --no-recreate >/dev/null 2>&1; then
            echo "[FAIL] archive processing failed and containers could not be restarted; recovery required" >&2
            rc=1
        fi
    fi
    [[ -z ${TAR_FILE} ]] || rm -f -- "${TAR_FILE}"
    [[ -z ${PUBLISH_TMP} ]] || rm -f -- "${PUBLISH_TMP}"
    exit "${rc}"
}
trap cleanup EXIT

[[ -d "${PROJECT_ROOT}/volumes" ]] || { echo "[FAIL] ${PROJECT_ROOT}/volumes not found" >&2; exit 1; }
OUTPUT_DIR="$(dirname "${OUT}")"
mkdir -p "${OUTPUT_DIR}"
TAR_FILE="$(mktemp "${OUTPUT_DIR}/.zt-backup.tar.XXXXXX")"

# Stop/start the whole project, including any docker-compose.override.yml
# user services, so the snapshot is consistent.
echo "[1/4] Stopping containers for a consistent snapshot..."
docker compose "${COMPOSE_ARGS[@]}" stop
STOPPED=true

echo "[2/4] Archiving the project runtime state..."
TAR_ARGS=(-C "$(dirname "${PROJECT_ROOT}")")
BASE="$(basename "${PROJECT_ROOT}")"
for member in "volumes" "docker-compose.yml" "Caddyfile" "Caddyfile.d" "docker-compose.override.yml"; do
    [[ -e "${PROJECT_ROOT}/${member}" ]] && TAR_ARGS+=("${BASE}/${member}")
done
tar -czf "${TAR_FILE}" "${TAR_ARGS[@]}"
# Verify the archive is readable before moving on.
tar -tzf "${TAR_FILE}" >/dev/null
chmod 600 "${TAR_FILE}"
[[ -s ${TAR_FILE} && $(stat -c '%a' "${TAR_FILE}") == 600 ]] \
    || { echo "[FAIL] private plaintext archive validation failed" >&2; exit 1; }

if [[ ${ALLOW_PLAINTEXT} == false ]]; then
    echo "[3/4] Encrypting with age..."
    FINAL_OUT="${OUT}.age"
    PUBLISH_TMP="$(mktemp "${OUTPUT_DIR}/.zt-backup.publish.XXXXXX")"
    age -r "${AGE_KEY}" "${TAR_FILE}" >"${PUBLISH_TMP}"
    chmod 600 "${PUBLISH_TMP}"
    [[ -s ${PUBLISH_TMP} && $(stat -c '%a' "${PUBLISH_TMP}") == 600 ]] \
        || { echo "[FAIL] encrypted archive validation failed" >&2; exit 1; }
else
    echo "[3/4] Explicit plaintext backup requested." >&2
    FINAL_OUT="${OUT}"
    PUBLISH_TMP="${TAR_FILE}"
fi

if ! ln -- "${PUBLISH_TMP}" "${FINAL_OUT}"; then
    echo "[FAIL] destination already exists; backup was not published: ${FINAL_OUT}" >&2
    exit 1
fi
rm -f -- "${PUBLISH_TMP}"
rm -f -- "${TAR_FILE}"
PUBLISH_TMP=
TAR_FILE=

STOPPED=false
if ! docker compose "${COMPOSE_ARGS[@]}" up -d --no-recreate >/dev/null 2>&1; then
    echo "[FAIL] backup published at ${FINAL_OUT}, but containers could not be restarted; recovery required" >&2
    exit 1
fi

echo "[4/4] Rotating old backups (keeping ${KEEP})..."
if [[ -d /opt/zt-backups ]]; then
    find /opt/zt-backups -maxdepth 1 -type f -name 'zt-*.tar.gz*' -print0 \
        | sort -zr \
        | tail -n +$((KEEP + 1)) -z \
        | xargs -0 -r rm -f
fi

echo "[OK] Backup written to ${FINAL_OUT} ($(du -h "${FINAL_OUT}" | cut -f1))"
