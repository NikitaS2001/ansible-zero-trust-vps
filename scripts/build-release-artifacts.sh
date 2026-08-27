#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    printf 'usage: %s --tag TAG --sha SHA --output EMPTY_DIR\n' "$0" >&2
    exit 2
}

tag=''
sha=''
output=''
while (($#)); do
    (($# >= 2)) || usage
    case "$1" in
        --tag) tag="$2" ;;
        --sha) sha="$2" ;;
        --output) output="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ \
    && "${sha}" =~ ^[0-9a-f]{40}$ ]] || usage
[[ -d "${output}" && ! -L "${output}" ]] \
    || { printf 'output must be an existing regular directory\n' >&2; exit 1; }
[[ -z "$(find "${output}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || { printf 'output directory must be empty\n' >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
head_sha="$(git -C "${ROOT_DIR}" rev-parse 'HEAD^{commit}')"
tag_sha="$(git -C "${ROOT_DIR}" rev-parse "refs/tags/${tag}^{commit}" 2>/dev/null || true)"
[[ "${head_sha}" == "${sha}" && "${tag_sha}" == "${sha}" ]] \
    || { printf 'tag, SHA, and HEAD must identify the same commit\n' >&2; exit 1; }
[[ -z "$(git -C "${ROOT_DIR}" status --porcelain=v1 --untracked-files=all)" ]] \
    || { printf 'source worktree must be clean\n' >&2; exit 1; }

output_parent="$(cd "$(dirname "${output}")" && pwd)"
output_name="$(basename "${output}")"
stage="$(mktemp -d "${output_parent}/.${output_name}.XXXXXX")"
cleanup() { [[ -z "${stage}" ]] || rm -rf -- "${stage}"; }
trap cleanup EXIT INT TERM

for name in install.sh CHANGELOG.md RELEASE_NOTES.md UPGRADE.md; do
    git -C "${ROOT_DIR}" show "${sha}:${name}" >"${stage}/${name}"
done
chmod 0755 "${stage}/install.sh"
chmod 0644 "${stage}/CHANGELOG.md" "${stage}/RELEASE_NOTES.md" "${stage}/UPGRADE.md"

LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="$(git -C "${ROOT_DIR}" show -s --format=%ct "${sha}")" \
    "${SCRIPT_DIR}/build-spdx-sbom.sh" \
    --tag "${tag}" --sha "${sha}" --output "${stage}/sbom.spdx.json"
chmod 0644 "${stage}/sbom.spdx.json"

(cd "${stage}" && sha256sum install.sh >install.sh.sha256)
for name in CHANGELOG.md RELEASE_NOTES.md UPGRADE.md install.sh install.sh.sha256 sbom.spdx.json; do
    (cd "${stage}" && sha256sum "${name}")
done >"${stage}/SHA256SUMS"
chmod 0644 "${stage}/install.sh.sha256" "${stage}/SHA256SUMS"

expected=$'CHANGELOG.md\nRELEASE_NOTES.md\nSHA256SUMS\nUPGRADE.md\ninstall.sh\ninstall.sh.sha256\nsbom.spdx.json'
[[ "$(find "${stage}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" == "${expected}" ]] \
    || { printf 'staged release membership is invalid\n' >&2; exit 1; }
if ! git -C "${ROOT_DIR}" diff --quiet -- \
    || ! git -C "${ROOT_DIR}" diff --cached --quiet --; then
    printf 'tracked source changed during build\n' >&2
    exit 1
fi

rmdir "${output}"
mv -- "${stage}" "${output}"
stage=''
trap - EXIT INT TERM
