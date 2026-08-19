#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_REVISION="${RELEASE_CONTRACT_SOURCE_REVISION:-}"

usage() {
    echo "usage: $0 [--case CASE]" >&2
}

case_name="all"
if [[ $# -gt 0 ]]; then
    [[ $# -eq 2 && "$1" == "--case" ]] || { usage; exit 2; }
    case_name="$2"
fi

repo=""
cleanup() {
    if [[ -n "${repo}" && -d "${repo}" ]]; then
        git -C "${repo}" tag -d v1.1.0 >/dev/null 2>&1 || true
        rm -rf -- "${repo}"
    fi
}
trap cleanup EXIT

make_repo() {
    cleanup
    repo="$(mktemp -d "${TMPDIR:-/tmp}/release-contract.XXXXXX")"
    mkdir -p "${repo}/scripts"
    if [[ -n "${SOURCE_REVISION}" ]]; then
        git -C "${SOURCE_ROOT}" show "${SOURCE_REVISION}:scripts/release-contract.sh" >"${repo}/scripts/release-contract.sh"
    else
        cp "${SOURCE_ROOT}/scripts/release-contract.sh" "${repo}/scripts/release-contract.sh"
    fi
    chmod 0755 "${repo}/scripts/release-contract.sh"
    printf '%s\n' \
        "readonly RELEASE_REF=\"\${ZERO_TRUST_RELEASE_REF:-v1.1.0}\"" \
        >"${repo}/install.sh"
    printf '%s\n' \
        'curl -fsSL https://raw.githubusercontent.com/example/repo/v1.1.0/install.sh | sudo bash' \
        >"${repo}/README.md"
    : >"${repo}/site.yml"
    printf '%s\n' \
        '---' \
        'collections:' \
        '  - name: community.docker' \
        '    version: "==4.8.7"' \
        '  - name: community.general' \
        '    version: "==13.2.0"' \
        '  - name: ansible.posix' \
        '    version: "==1.6.0"' \
        >"${repo}/requirements.yml"
    git -C "${repo}" init -q
    git -C "${repo}" config user.email release-contract@example.invalid
    git -C "${repo}" config user.name release-contract
    git -C "${repo}" add .
    git -C "${repo}" commit -qm fixture
}

run_case() {
    local name="$1"
    make_repo
    case "${name}" in
        pr-valid)
            "${repo}/scripts/release-contract.sh" --pr
            ;;
        missing-pin-first)
            sed -i '/^    version: "==4.8.7"$/d' "${repo}/requirements.yml"
            expect_rejection "${name}" "${repo}/scripts/release-contract.sh" --pr
            ;;
        missing-pin-middle)
            sed -i '/^    version: "==13.2.0"$/d' "${repo}/requirements.yml"
            expect_rejection "${name}" "${repo}/scripts/release-contract.sh" --pr
            ;;
        missing-pin-last)
            sed -i '/^    version: "==1.6.0"$/d' "${repo}/requirements.yml"
            expect_rejection "${name}" "${repo}/scripts/release-contract.sh" --pr
            ;;
        nonexact-pin)
            sed -i 's/^    version: "==4.8.7"$/    version: "==4.8.7" # not exact/' "${repo}/requirements.yml"
            expect_rejection "${name}" "${repo}/scripts/release-contract.sh" --pr
            ;;
        readme-install-mismatch)
            sed -i 's/v1.1.0/v9.9.9/' "${repo}/README.md"
            expect_rejection "${name}" "${repo}/scripts/release-contract.sh" --pr
            ;;
        tag-at-head)
            git -C "${repo}" tag -am fixture v1.1.0
            GITHUB_REF_NAME=v1.1.0 "${repo}/scripts/release-contract.sh" --tag
            ;;
        nonexistent-tag)
            expect_rejection "${name}" env GITHUB_REF_NAME=v1.1.0 "${repo}/scripts/release-contract.sh" --tag
            ;;
        tag-not-at-head)
            git -C "${repo}" tag -am fixture v1.1.0
            printf '%s\n' 'stale head' >>"${repo}/README.md"
            git -C "${repo}" add README.md
            git -C "${repo}" commit -qm stale-head
            expect_rejection "${name}" env GITHUB_REF_NAME=v1.1.0 "${repo}/scripts/release-contract.sh" --tag
            ;;
        dirty-worktree)
            git -C "${repo}" tag -am fixture v1.1.0
            printf '%s\n' 'uncommitted mutation' >>"${repo}/README.md"
            expect_rejection "${name}" env GITHUB_REF_NAME=v1.1.0 "${repo}/scripts/release-contract.sh" --tag
            ;;
        malformed-option)
            expect_rejection "${name}" "${repo}/scripts/release-contract.sh" --unknown
            ;;
        *)
            usage
            return 2
            ;;
    esac
    echo "[PASS] ${name}"
}

expect_rejection() {
    local name="$1"
    shift
    if "$@"; then
        echo "[FAIL] ${name}: expected nonzero release-contract exit" >&2
        return 1
    fi
}

case "${case_name}" in
    all)
        run_case pr-valid
        run_case missing-pin-first
        run_case missing-pin-middle
        run_case missing-pin-last
        run_case nonexact-pin
        run_case readme-install-mismatch
        run_case tag-at-head
        run_case nonexistent-tag
        run_case tag-not-at-head
        run_case dirty-worktree
        run_case malformed-option
        ;;
    pr-valid | missing-pin-first | missing-pin-middle | missing-pin-last | nonexact-pin | readme-install-mismatch | tag-at-head | nonexistent-tag | tag-not-at-head | dirty-worktree | malformed-option)
        run_case "${case_name}"
        ;;
    *)
        usage
        exit 2
        ;;
esac
