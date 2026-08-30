#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-artifacts.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT INT TERM

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
reject() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then fail "accepted ${label}"; fi
    printf '[PASS] rejected %s\n' "${label}"
}

repo="${tmp}/repo"
mkdir -p "${repo}/scripts" "${repo}/.github" \
    "${repo}/roles/vps_orchestration/defaults" \
    "${repo}/roles/vps_orchestration/templates"
cp "${ROOT_DIR}/scripts/build-release-artifacts.sh" \
    "${ROOT_DIR}/scripts/build-spdx-sbom.sh" \
    "${ROOT_DIR}/scripts/release-contract.sh" "${repo}/scripts/"
cp "${ROOT_DIR}/install.sh" "${ROOT_DIR}/requirements.yml" \
    "${ROOT_DIR}/CHANGELOG.md" "${ROOT_DIR}/RELEASE_NOTES.md" \
    "${ROOT_DIR}/UPGRADE.md" "${repo}/"
cp "${ROOT_DIR}/roles/vps_orchestration/defaults/main.yml" \
    "${repo}/roles/vps_orchestration/defaults/main.yml"
cp "${ROOT_DIR}/roles/vps_orchestration/templates/docker-compose.yml.j2" \
    "${repo}/roles/vps_orchestration/templates/docker-compose.yml.j2"
key="${tmp}/signer"
ssh-keygen -q -t ed25519 -N '' -f "${key}"
identity='release-fixture@example.invalid'
sed -i \
    -e 's/^readonly OFFICIAL_RELEASE_REF=.*/readonly OFFICIAL_RELEASE_REF="v1.3.0"/' \
    -e "s/^readonly OFFICIAL_SIGNER_IDENTITY=.*/readonly OFFICIAL_SIGNER_IDENTITY=\"${identity}\"/" \
    -e "s#^readonly OFFICIAL_SIGNER_PUBLIC_KEY=.*#readonly OFFICIAL_SIGNER_PUBLIC_KEY=\"$(<"${key}.pub")\"#" \
    "${repo}/install.sh"
printf '%s %s\n' "${identity}" "$(<"${key}.pub")" >"${repo}/.github/release-allowed-signers"
git -C "${repo}" init -q
git -C "${repo}" config user.name 'Release Fixture'
git -C "${repo}" config user.email "${identity}"
git -C "${repo}" add .
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    git -C "${repo}" -c commit.gpgsign=false commit -qm fixture
sha="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" -c gpg.format=ssh -c user.signingkey="${key}" tag -sam fixture v1.3.0

mkdir "${tmp}/one" "${tmp}/two"
"${repo}/scripts/build-release-artifacts.sh" --tag v1.3.0 --sha "${sha}" --output "${tmp}/one"
"${repo}/scripts/build-release-artifacts.sh" --tag v1.3.0 --sha "${sha}" --output "${tmp}/two"
"${repo}/scripts/release-contract.sh" --assets "${tmp}/one" --tag v1.3.0 --sha "${sha}"
diff -qr "${tmp}/one" "${tmp}/two" >/dev/null || fail 'two builds differ'
printf '[PASS] deterministic seven-file build\n'

mkdir "${repo}/release"
"${repo}/scripts/build-release-artifacts.sh" \
    --tag v1.3.0 --sha "${sha}" --output "${repo}/release"
"${repo}/scripts/release-contract.sh" \
    --assets "${repo}/release" --tag v1.3.0 --sha "${sha}"
rm -rf -- "${repo}/release"
printf '[PASS] in-worktree release directory\n'

cp -a "${tmp}/one" "${tmp}/mutant"
printf 'extra\n' >"${tmp}/mutant/extra"
reject extra-asset "${repo}/scripts/release-contract.sh" \
    --assets "${tmp}/mutant" --tag v1.3.0 --sha "${sha}"
rm "${tmp}/mutant/extra"
printf 'tamper\n' >>"${tmp}/mutant/install.sh"
reject checksum-mismatch "${repo}/scripts/release-contract.sh" \
    --assets "${tmp}/mutant" --tag v1.3.0 --sha "${sha}"
mkdir "${tmp}/nonempty"
printf x >"${tmp}/nonempty/x"
reject nonempty-output "${repo}/scripts/build-release-artifacts.sh" \
    --tag v1.3.0 --sha "${sha}" --output "${tmp}/nonempty"
reject wrong-sha "${repo}/scripts/build-release-artifacts.sh" \
    --tag v1.3.0 --sha 0000000000000000000000000000000000000000 --output "${tmp}/nonempty"

printf 'RELEASE ARTIFACTS PASS sha=%s\n' "${sha}"
