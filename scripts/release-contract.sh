#!/usr/bin/env bash
# Release contract verification.
#
# --pr (default, structural, runs on every pull request):
#   - install.sh default ZERO_TRUST_RELEASE_REF is a vX.Y.Z tag
#   - the README quickstart URL uses the same tag
#   - requirements.yml pins every collection to an exact "==" version
#
# --tag (strict, runs on tag pushes / release gates):
#   - everything from --pr
#   - the current git tag matches the installer default
#   - install.sh *inside* the tag references the same tag (self-consistency:
#     the tagged installer must deploy exactly that tag)
#   - prints SHA256 checksums of the release artifacts for the release notes
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

MODE="${1:---pr}"
case "${MODE}" in
    --pr | --tag) ;;
    *) echo "usage: $0 [--pr|--tag]" >&2; exit 2 ;;
esac

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }
isolated_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }

release_ref="$(sed -nE 's/^readonly OFFICIAL_RELEASE_REF="([^"]+)"$/\1/p' install.sh)"
signer_identity="$(sed -nE 's/^readonly OFFICIAL_SIGNER_IDENTITY="([^"]+)"$/\1/p' install.sh)"
signer_public_key="$(sed -nE 's/^readonly OFFICIAL_SIGNER_PUBLIC_KEY="([^"]+)"$/\1/p' install.sh)"
[[ -n "${release_ref}" ]] || fail "install.sh must define OFFICIAL_RELEASE_REF"
[[ -n "${signer_identity}" ]] || fail "install.sh must define OFFICIAL_SIGNER_IDENTITY"
[[ -n "${signer_public_key}" ]] || fail "install.sh must define OFFICIAL_SIGNER_PUBLIC_KEY"

allowed_signers_file=""
cleanup() { [[ -z "${allowed_signers_file}" ]] || rm -f -- "${allowed_signers_file}"; }
trap cleanup EXIT
trap 'exit 129' HUP INT TERM

if [[ "${MODE}" == "--tag" ]]; then
    tag_name="${GITHUB_REF_NAME:-$(isolated_git describe --tags --exact-match 2>/dev/null || true)}"
    [[ -n "${tag_name}" ]] || fail "--tag mode requires HEAD to be exactly a git tag"
    tag_type="$(isolated_git cat-file -t "refs/tags/${tag_name}" 2>/dev/null || true)"
    [[ "${tag_type}" == "tag" ]] \
        || fail "git tag '${tag_name}' is not a trusted SSH-signed tag (annotated tag required)"
    allowed_signers_file="$(mktemp "${TMPDIR:-/tmp}/release-contract-signers.XXXXXX")"
    chmod 0600 "${allowed_signers_file}"
    printf '%s %s\n' "${signer_identity}" "${signer_public_key}" >"${allowed_signers_file}"
    isolated_git \
        -c gpg.format=ssh \
        -c gpg.ssh.allowedSignersFile="${allowed_signers_file}" \
        verify-tag "${tag_name}" >/dev/null 2>&1 \
        || fail "git tag '${tag_name}' is not a trusted SSH-signed tag"
    tagger_email="$(isolated_git for-each-ref --format='%(taggeremail)' "refs/tags/${tag_name}")"
    [[ "${tagger_email}" == "<${signer_identity}>" ]] \
        || fail "git tag '${tag_name}' is not a trusted SSH-signed tag (tagger identity mismatch)"
    pass "trusted SSH-signed tag ${tag_name}"
    tag_commit="$(isolated_git rev-parse --verify --quiet "${tag_name}^{commit}")" \
        || fail "git tag '${tag_name}' does not resolve to a commit"
    head_commit="$(isolated_git rev-parse --verify --quiet 'HEAD^{commit}')" \
        || fail "HEAD does not resolve to a commit"
    [[ "${tag_commit}" == "${head_commit}" ]] \
        || fail "git tag '${tag_name}' does not point at HEAD"
    [[ -z "$(isolated_git status --porcelain=v1)" ]] \
        || fail "--tag mode requires a clean worktree"
fi

[[ "${release_ref}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "OFFICIAL_RELEASE_REF must be a vX.Y.Z tag; got '${release_ref}'"
pass "installer OFFICIAL_RELEASE_REF=${release_ref}"

quickstart_ref="$(
    grep -oE 'raw\.githubusercontent\.com/[^/]+/[^/]+/v[0-9]+\.[0-9]+\.[0-9]+/install\.sh' README.md \
        | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true
)"
[[ "${quickstart_ref}" == "${release_ref}" ]] \
    || fail "README quickstart tag '${quickstart_ref:-<none>}' does not match RELEASE_REF '${release_ref}'"
pass "README quickstart uses ${release_ref}"

# Every collection must have an exact "==" version: a missing version line
# would let ansible-galaxy install any version. awk exits 1 when a - name:
# entry ends without a "version: \"==\"" line.
if awk '
    function finish_entry() {
        if (in_entry && !has_pin) exit 1
    }
    /^  - name:/ {
        finish_entry()
        in_entry = 1
        has_pin = 0
        next
    }
    in_entry && /^    version: "==[^"]+"[[:space:]]*$/ { has_pin = 1 }
    END { finish_entry() }
' requirements.yml; then
    pass "requirements.yml pins every collection exactly"
else
    fail "every collection must be pinned with an exact '==' version"
fi

if [[ "${MODE}" == "--pr" ]]; then
    pass "release contract (structural) OK"
    exit 0
fi

# --tag: strict checks
[[ "${tag_name}" == "${release_ref}" ]] \
    || fail "git tag '${tag_name}' does not match installer default '${release_ref}'"

in_tag_ref="$(
    isolated_git show "${tag_name}:install.sh" \
        | sed -nE 's/^readonly OFFICIAL_RELEASE_REF="([^"]+)"$/\1/p'
)"
[[ "${in_tag_ref}" == "${tag_name}" ]] \
    || fail "install.sh inside ${tag_name} references '${in_tag_ref}', not '${tag_name}'"
pass "install.sh inside ${tag_name} is self-consistent (deploys ${tag_name})"

echo "--- SHA256 (publish in the release notes) ---"
sha256sum install.sh site.yml requirements.yml scripts/release-contract.sh
pass "release contract (tag) OK"
