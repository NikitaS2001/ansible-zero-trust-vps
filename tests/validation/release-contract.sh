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
key_dir=""
host_git_config=""
signer_tmp=""
cleanup() {
    if [[ -n "${repo}" && -d "${repo}" ]]; then
        git -C "${repo}" tag -d v1.1.0 >/dev/null 2>&1 || true
        rm -rf -- "${repo}"
    fi
    [[ -z "${key_dir}" || ! -d "${key_dir}" ]] || rm -rf -- "${key_dir}"
}
trap cleanup EXIT

make_repo() {
    cleanup
    repo="$(mktemp -d "${TMPDIR:-/tmp}/release-contract.XXXXXX")"
    key_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-contract-key.XXXXXX")"
    ssh-keygen -q -t ed25519 -N '' -f "${key_dir}/signer"
    ssh-keygen -q -t ed25519 -N '' -f "${key_dir}/stale-signer"
    host_git_config="${key_dir}/host-gitconfig"
    signer_tmp="${key_dir}/tmp"
    mkdir "${signer_tmp}"
    printf '%s %s\n' release-contract@example.invalid "$(cat "${key_dir}/stale-signer.pub")" \
        >"${signer_tmp}/stale-allowed-signers"
    printf '%s\n' \
        '[gpg]' \
        '    format = openpgp' \
        '[gpg "ssh"]' \
        "    allowedSignersFile = ${signer_tmp}/stale-allowed-signers" \
        >"${host_git_config}"
    mkdir -p "${repo}/scripts"
    if [[ -n "${SOURCE_REVISION}" ]]; then
        git -C "${SOURCE_ROOT}" show "${SOURCE_REVISION}:scripts/release-contract.sh" >"${repo}/scripts/release-contract.sh"
    else
        cp "${SOURCE_ROOT}/scripts/release-contract.sh" "${repo}/scripts/release-contract.sh"
    fi
    chmod 0755 "${repo}/scripts/release-contract.sh"
    fixture_key="$(cat "${key_dir}/signer.pub")"
    printf '%s\n' \
        'readonly OFFICIAL_RELEASE_REF="v1.1.0"' \
        'readonly OFFICIAL_SIGNER_IDENTITY="release-contract@example.invalid"' \
        "readonly OFFICIAL_SIGNER_PUBLIC_KEY=\"${fixture_key}\"" \
        "readonly RELEASE_REF=\"\${OFFICIAL_RELEASE_REF}\"" \
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

sign_tag() {
    local key="${1:-${key_dir}/signer}"
    git -C "${repo}" \
        -c gpg.format=ssh \
        -c user.signingkey="${key}" \
        tag -sam fixture v1.1.0
}

run_strict_gate() {
    local before after files_before files_after head_before head_after status_before status_after status=0
    before="$(sha256sum "${host_git_config}")"
    files_before="$(find "${signer_tmp}" -maxdepth 1 -type f -printf '%f\n' | sort)"
    head_before="$(git -C "${repo}" rev-parse HEAD)"
    status_before="$(git -C "${repo}" status --porcelain=v1)"
    GIT_CONFIG_GLOBAL="${host_git_config}" TMPDIR="${signer_tmp}" GITHUB_REF_NAME=v1.1.0 \
        "${repo}/scripts/release-contract.sh" --tag || status=$?
    after="$(sha256sum "${host_git_config}")"
    files_after="$(find "${signer_tmp}" -maxdepth 1 -type f -printf '%f\n' | sort)"
    head_after="$(git -C "${repo}" rev-parse HEAD)"
    status_after="$(git -C "${repo}" status --porcelain=v1)"
    [[ "${after}" == "${before}" ]] || { echo '[FAIL] host Git config was modified' >&2; return 1; }
    [[ "${files_after}" == "${files_before}" ]] \
        || { echo '[FAIL] temporary allowed-signers files were not restored' >&2; return 1; }
    [[ "${head_after}" == "${head_before}" && "${status_after}" == "${status_before}" ]] \
        || { echo '[FAIL] release gate modified fixture HEAD or worktree' >&2; return 1; }
    return "${status}"
}

run_signed_tag() {
    local output
    sign_tag
    output="$(run_strict_gate)"
    printf '%s\n' "${output}"
    grep -Fq '[PASS] trusted SSH-signed tag v1.1.0' <<<"${output}" \
        || { echo '[FAIL] signed-tag: missing signature verification result' >&2; return 1; }
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
            run_signed_tag
            ;;
        lightweight-tag)
            git -C "${repo}" tag v1.1.0
            expect_trust_rejection "${name}"
            ;;
        unsigned-tag)
            git -C "${repo}" tag -am '[PASS] trusted SSH-signed tag v1.1.0' v1.1.0
            expect_trust_rejection "${name}"
            ;;
        wrong-key-tag)
            ssh-keygen -q -t ed25519 -N '' -f "${key_dir}/wrong"
            sign_tag "${key_dir}/wrong"
            expect_trust_rejection "${name}"
            ;;
        invalid-signature-tag)
            sign_tag
            tampered_tag="$(git -C "${repo}" cat-file tag refs/tags/v1.1.0 \
                | sed '0,/^fixture$/s//tampered/' \
                | git -C "${repo}" hash-object -t tag -w --stdin)"
            git -C "${repo}" update-ref refs/tags/v1.1.0 "${tampered_tag}"
            expect_trust_rejection "${name}"
            ;;
        wrong-identity-tag)
            git -C "${repo}" config user.email attacker@example.invalid
            sign_tag
            expect_trust_rejection "${name}"
            ;;
        interrupted-cleanup)
            sign_tag
            real_git="$(command -v git)"
            mkdir "${key_dir}/bin"
            printf '%s\n' \
                '#!/usr/bin/env bash' \
                'if [[ " $* " == *" verify-tag "* ]]; then' \
                "    printf '%s\\n' \"\${PPID}\" >\"${key_dir}/verify-parent\"" \
                '    sleep 0.5' \
                'fi' \
                "exec \"${real_git}\" \"\$@\"" \
                >"${key_dir}/bin/git"
            chmod 0755 "${key_dir}/bin/git"
            for _ in 1 2; do
                rm -f -- "${key_dir}/verify-parent"
                PATH="${key_dir}/bin:${PATH}" run_strict_gate >/dev/null 2>&1 &
                gate_pid=$!
                for _ in {1..100}; do
                    [[ -s "${key_dir}/verify-parent" ]] && break
                    sleep 0.01
                done
                [[ -s "${key_dir}/verify-parent" ]] \
                    || { echo '[FAIL] interrupted-cleanup: verification did not start' >&2; return 1; }
                kill -TERM "$(cat "${key_dir}/verify-parent")"
                if wait "${gate_pid}"; then
                    echo '[FAIL] interrupted-cleanup: interrupted gate unexpectedly passed' >&2
                    return 1
                fi
            done
            ;;
        nonexistent-tag)
            expect_rejection "${name}" run_strict_gate
            ;;
        tag-not-at-head)
            sign_tag
            printf '%s\n' 'stale head' >>"${repo}/README.md"
            git -C "${repo}" add README.md
            git -C "${repo}" commit -qm stale-head
            expect_rejection "${name}" run_strict_gate
            ;;
        dirty-worktree)
            sign_tag
            printf '%s\n' 'uncommitted mutation' >>"${repo}/README.md"
            expect_rejection "${name}" run_strict_gate
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

expect_trust_rejection() {
    local name="$1" output
    if output="$(run_strict_gate 2>&1)"; then
        echo "[FAIL] ${name}: expected nonzero release-contract exit" >&2
        return 1
    fi
    grep -Fq 'trusted SSH-signed tag' <<<"${output}" \
        || { printf '[FAIL] %s: rejection did not identify the signed-tag trust policy\n%s\n' "${name}" "${output}" >&2; return 1; }
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
        run_case lightweight-tag
        run_case unsigned-tag
        run_case wrong-key-tag
        run_case invalid-signature-tag
        run_case wrong-identity-tag
        run_case interrupted-cleanup
        ;;
    signed-tag)
        run_case tag-at-head
        ;;
    rejected-signatures)
        run_case lightweight-tag
        run_case unsigned-tag
        run_case wrong-key-tag
        run_case invalid-signature-tag
        run_case wrong-identity-tag
        ;;
    pr-valid | missing-pin-first | missing-pin-middle | missing-pin-last | nonexact-pin | readme-install-mismatch | tag-at-head | nonexistent-tag | tag-not-at-head | dirty-worktree | malformed-option | lightweight-tag | unsigned-tag | wrong-key-tag | invalid-signature-tag | wrong-identity-tag | interrupted-cleanup)
        run_case "${case_name}"
        ;;
    *)
        usage
        exit 2
        ;;
esac
