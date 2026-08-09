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

release_ref="$(
    sed -nE 's/^readonly RELEASE_REF="\$\{ZERO_TRUST_RELEASE_REF:-([^}]+)\}"$/\1/p' install.sh
)"
[[ -n "${release_ref}" ]] || fail "install.sh must define a default ZERO_TRUST_RELEASE_REF"
[[ "${release_ref}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "default ZERO_TRUST_RELEASE_REF must be a vX.Y.Z tag; got '${release_ref}'"
pass "installer default ZERO_TRUST_RELEASE_REF=${release_ref}"

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
    /^  - name:/ { in_entry = 1; has_pin = 0; next }
    in_entry && /^    version: "==/ { has_pin = 1; next }
    in_entry && /^    version:/ { next }
    in_entry && /^[^ ]/ { if (!has_pin) exit 1; in_entry = 0 }
    END { if (in_entry && !has_pin) exit 1 }
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
tag_name="${GITHUB_REF_NAME:-$(git describe --tags --exact-match 2>/dev/null || true)}"
[[ -n "${tag_name}" ]] || fail "--tag mode requires HEAD to be exactly a git tag"
[[ "${tag_name}" == "${release_ref}" ]] \
    || fail "git tag '${tag_name}' does not match installer default '${release_ref}'"

in_tag_ref="$(
    git show "${tag_name}:install.sh" \
        | sed -nE 's/^readonly RELEASE_REF="\$\{ZERO_TRUST_RELEASE_REF:-([^}]+)\}"$/\1/p'
)"
[[ "${in_tag_ref}" == "${tag_name}" ]] \
    || fail "install.sh inside ${tag_name} references '${in_tag_ref}', not '${tag_name}'"
pass "install.sh inside ${tag_name} is self-consistent (deploys ${tag_name})"

echo "--- SHA256 (publish in the release notes) ---"
sha256sum install.sh site.yml requirements.yml scripts/release-contract.sh
pass "release contract (tag) OK"
