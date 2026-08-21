#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2317,SC2329

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

run_child_leak_sentinel() (
    export ZERO_TRUST_NONINTERACTIVE=1
    export ZERO_TRUST_ADMIN_PASSWORD='fixture-admin-value'
    export ZERO_TRUST_ADGUARD_PASSWORD='fixture-adguard-value'
    export ZERO_TRUST_WG_PASSWORD='fixture-wireguard-value'
    export ZERO_TRUST_SSH_PUBKEY='ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'
    export INHERITED_ADMIN_PASSWORD='attacker-preexported-value'
    export INHERITED_ADGUARD_PASSWORD='attacker-preexported-value'
    export INHERITED_WG_PASSWORD='attacker-preexported-value'
    export INHERITED_SSH_PUBKEY='attacker-preexported-value'
    export ADMIN_PASSWORD='attacker-preexported-value'
    export ADGUARD_PASSWORD='attacker-preexported-value'
    export WG_PASSWORD='attacker-preexported-value'
    export SSH_PUBKEY='attacker-preexported-value'

    # shellcheck source=../../install.sh
    source "${ROOT_DIR}/install.sh"

    assert_clean_child_environment() {
        local child_output
        child_output="$(INSTALLER_CONTRACT_SENTINEL=visible env)"
        [[ "${child_output}" == *'INSTALLER_CONTRACT_SENTINEL=visible'* ]] || fail 'child environment probe did not detect its sentinel'
        [[ "${child_output}" != *'ZERO_TRUST_ADMIN_PASSWORD='* ]] || fail 'admin secret name reached a child'
        [[ "${child_output}" != *'ZERO_TRUST_ADGUARD_PASSWORD='* ]] || fail 'AdGuard secret name reached a child'
        [[ "${child_output}" != *'ZERO_TRUST_WG_PASSWORD='* ]] || fail 'WireGuard secret name reached a child'
        [[ "${child_output}" != *'ZERO_TRUST_SSH_PUBKEY='* ]] || fail 'SSH key name reached a child'
        [[ "${child_output}" != *'fixture-admin-value'* ]] || fail 'admin fixture value reached a child'
        [[ "${child_output}" != *'fixture-adguard-value'* ]] || fail 'AdGuard fixture value reached a child'
        [[ "${child_output}" != *'fixture-wireguard-value'* ]] || fail 'WireGuard fixture value reached a child'
        [[ "${child_output}" != *'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'* ]] || fail 'SSH key fixture value reached a child'
    }
    require_root() { :; }
    require_supported_os() { :; }
    validate_release_source() { assert_clean_child_environment; }
    resolve_wg_host() { WG_HOST='192.0.2.10'; }
    install_prerequisites() { assert_clean_child_environment; }
    install_ansible_toolchain() { :; }
    checkout_release() { :; }
    install_collections() { :; }
    run_ansible_pull() { :; }
    print_summary() { :; }

    main
    printf '[PASS] child-leak-sentinel: guarded main removes inherited secrets before the first child\n'
)

run_suffix_summary() (
    local suffix="$1"
    local expected_suffix="$2"

    export ZERO_TRUST_NONINTERACTIVE=1
    export ZERO_TRUST_ADMIN_PASSWORD='fixture-admin-value'
    export ZERO_TRUST_ADGUARD_PASSWORD='fixture-adguard-value'
    export ZERO_TRUST_WG_PASSWORD='fixture-wireguard-value'
    export ZERO_TRUST_SSH_PUBKEY='ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'
    export ZERO_TRUST_SSH_PORT=2222
    export ZERO_TRUST_WG_PORT=51820
    export ZERO_TRUST_ADMIN_USER=sysadmin
    export ZERO_TRUST_WG_HOST=192.0.2.10
    export ZERO_TRUST_INTERNAL_DOMAIN_SUFFIX="${suffix}"

    # shellcheck source=../../install.sh
    source "${ROOT_DIR}/install.sh"

    require_root() { :; }
    require_supported_os() { :; }
    validate_release_source() { :; }
    install_prerequisites() { :; }
    install_ansible_toolchain() { :; }
    checkout_release() { :; }
    install_collections() { :; }
    run_ansible_pull() {
        unset ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY
        unset INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY
    }
    read_yaml_scalar_default() {
        case "$2" in
            wg_easy_bootstrap_ui_port) printf '%s\n' '51821' ;;
            adguard_bootstrap_ui_port) printf '%s\n' '3000' ;;
            internal_domain_suffix) printf '%s\n' 'internal' ;;
            *) printf '%s\n' 'unused' ;;
        esac
    }

    local summary
    summary="$(main)"
    [[ "${summary}" == *"https://wg.${expected_suffix}"* ]] || fail "suffix-only summary omitted wg.${expected_suffix}"
    [[ "${summary}" == *"https://adguard.${expected_suffix}"* ]] || fail "suffix-only summary omitted adguard.${expected_suffix}"
    [[ "${summary}" != *'{{'* ]] || fail 'suffix-only summary leaked an unresolved template'
    [[ "${summary}" != *'fixture-'* ]] || fail 'summary exposed a fixture value'
    if [[ "${expected_suffix}" != 'internal' ]]; then
        [[ "${summary}" != *'.internal'* ]] || fail 'custom suffix summary leaked the default suffix'
    fi
    printf '[PASS] suffix-%s: guarded main summary uses the effective suffix\n' "${expected_suffix}"
)

run_suffix_home_arpa() {
    run_suffix_summary home.arpa home.arpa
}

run_suffix_internal() {
    run_suffix_summary internal internal
}

run_piped_entry_guard() {
    local output

    # shellcheck disable=SC2016  # match the literal install.sh entry guard
    grep -Fq 'BASH_SOURCE[0]:-$0' "${ROOT_DIR}/install.sh" \
        || fail 'install.sh must invoke main when BASH_SOURCE is unset (curl | bash)'

    output="$(
        {
            printf '%s\n' 'set -euo pipefail' 'main() { printf "main-ran\n"; }'
            tail -n 4 "${ROOT_DIR}/install.sh"
        } | bash
    )"
    [[ "${output}" == 'main-ran' ]] || fail "piped install.sh entry guard did not invoke main: ${output}"
    printf '[PASS] piped-entry-guard: curl | bash reaches main under set -u\n'
}

run_env_clean() (
    local fixture_dir
    fixture_dir="$(command mktemp -d)"
    trap 'rm -rf "${fixture_dir}"' EXIT

    export ZERO_TRUST_NONINTERACTIVE=1
    export ZERO_TRUST_ADMIN_PASSWORD='fixture-admin-value'
    export ZERO_TRUST_ADGUARD_PASSWORD='fixture-adguard-value'
    export ZERO_TRUST_WG_PASSWORD='fixture-wireguard-value'
    export ZERO_TRUST_SSH_PUBKEY='ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'
    export ZERO_TRUST_WG_HOST=192.0.2.10

    # shellcheck source=../../install.sh
    source "${ROOT_DIR}/install.sh"

    require_root() { :; }
    require_supported_os() { :; }
    validate_release_source() { :; }
    install_prerequisites() { :; }
    install_ansible_toolchain() { :; }
    checkout_release() { :; }
    install_collections() { :; }
    ensure_install_root() { :; }
    mktemp() { command mktemp "${fixture_dir}/extra-vars.XXXXXX.yml"; }
    run_ansible_pull() {
        prepare_extra_vars_file
        [[ "$(stat -c '%a' "${EXTRA_VARS_FILE}")" == '600' ]] || fail 'extra-vars fixture mode is not 0600'
        grep -Fq 'fixture-admin-value' "${EXTRA_VARS_FILE}" || fail 'admin value did not reach extra-vars fixture'
        grep -Fq 'fixture-adguard-value' "${EXTRA_VARS_FILE}" || fail 'AdGuard value did not reach extra-vars fixture'
        grep -Fq 'fixture-wireguard-value' "${EXTRA_VARS_FILE}" || fail 'WireGuard value did not reach extra-vars fixture'
        grep -Fq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "${EXTRA_VARS_FILE}" || fail 'SSH key did not reach extra-vars fixture'
        [[ ! -v ADMIN_PASSWORD && ! -v ADGUARD_PASSWORD && ! -v WG_PASSWORD && ! -v SSH_PUBKEY ]] || fail 'working secret variables were retained after extra-vars write'
        [[ ! -v INHERITED_ADMIN_PASSWORD && ! -v INHERITED_ADGUARD_PASSWORD && ! -v INHERITED_WG_PASSWORD && ! -v INHERITED_SSH_PUBKEY ]] || fail 'copied inherited secrets were retained after extra-vars write'
        cleanup_extra_vars_file
    }
    print_summary() { :; }

    main
    printf '[PASS] env-clean: secrets reach only a mode-0600 extra-vars file and are then cleared\n'
)

init_release_fixture() {
    FIXTURE_DIR="$(command mktemp -d)"
    FIXTURE_REPO="${FIXTURE_DIR}/repo"
    FIXTURE_KEY="${FIXTURE_DIR}/trusted-key"
    FIXTURE_WRONG_KEY="${FIXTURE_DIR}/wrong-key"
    FIXTURE_ALLOWED_SIGNERS="${FIXTURE_DIR}/allowed-signers"
    FIXTURE_IDENTITY='release-fixture@example.test'
    FIXTURE_TAG='v1.2.3'

    git init --quiet "${FIXTURE_REPO}"
    git -C "${FIXTURE_REPO}" config user.name 'Release Fixture'
    git -C "${FIXTURE_REPO}" config user.email "${FIXTURE_IDENTITY}"
    printf 'fixture\n' >"${FIXTURE_REPO}/payload.txt"
    git -C "${FIXTURE_REPO}" add payload.txt
    git -C "${FIXTURE_REPO}" commit --quiet -m fixture
    printf 'unrelated dirty content\n' >"${FIXTURE_REPO}/unrelated.txt"
    ssh-keygen -q -t ed25519 -N '' -f "${FIXTURE_KEY}"
    ssh-keygen -q -t ed25519 -N '' -f "${FIXTURE_WRONG_KEY}"
}

write_fixture_allowed_signers() {
    local principal="${1:-${FIXTURE_IDENTITY}}"
    local key_file="${2:-${FIXTURE_KEY}.pub}"

    printf '%s %s\n' "${principal}" "$(cut -d' ' -f1-2 "${key_file}")" >"${FIXTURE_ALLOWED_SIGNERS}"
    chmod 0600 "${FIXTURE_ALLOWED_SIGNERS}"
}

sign_fixture_tag() {
    local key_file="${1:-${FIXTURE_KEY}}"
    local tagger_email="${2:-${FIXTURE_IDENTITY}}"
    local message="${3:-fixture release}"

    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${FIXTURE_REPO}" \
        -c user.name='Release Fixture' \
        -c user.email="${tagger_email}" \
        -c user.signingkey="${key_file}" \
        -c gpg.format=ssh \
        tag -s -a "${FIXTURE_TAG}" -m "${message}"
}

run_fixture_verifier() {
    local hostile_config="${FIXTURE_DIR}/hostile-gitconfig"

    git config --file "${hostile_config}" gpg.format openpgp
    git config --file "${hostile_config}" gpg.ssh.allowedSignersFile /dev/null
    GIT_CONFIG_GLOBAL="${hostile_config}" GIT_CONFIG_NOSYSTEM=0 bash -c '
        source "$1"
        ALLOWED_SIGNERS_FILE="$4"
        verify_signed_release "$2" "$3" "$4" "$5"
        touch "$6/configuration-collected" \
            "$6/extra-vars-created" \
            "$6/ansible-toolchain-installed" \
            "$6/ansible-collection-installed" \
            "$6/ansible-playbook-ran"
    ' _ "${ROOT_DIR}/install.sh" "${FIXTURE_REPO}" "${FIXTURE_TAG}" \
        "${FIXTURE_ALLOWED_SIGNERS}" "${FIXTURE_IDENTITY}" "${FIXTURE_DIR}"
}

cleanup_release_fixture() {
    local fixture_dir="${FIXTURE_DIR:-}"

    [[ -n "${fixture_dir}" ]] || return
    rm -rf "${fixture_dir}"
    [[ ! -e "${fixture_dir}" ]] || fail "fixture cleanup left ${fixture_dir}"
    FIXTURE_DIR=''
}

run_signed_release() (
    local output
    local expected_sha

    init_release_fixture
    trap cleanup_release_fixture EXIT
    write_fixture_allowed_signers
    sign_fixture_tag
    expected_sha="$(git -C "${FIXTURE_REPO}" rev-parse "${FIXTURE_TAG}^{commit}")"

    output="$(run_fixture_verifier 2>&1)" || fail "signed annotated release was rejected: ${output}"
    [[ "${output}" == *"${FIXTURE_IDENTITY}"* ]] || fail 'accepted release did not expose signer identity'
    [[ "${output}" == *"${expected_sha}"* ]] || fail 'accepted release did not expose its full commit SHA'
    [[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || fail 'fixture did not resolve to a full SHA'
    [[ ! -e "${FIXTURE_ALLOWED_SIGNERS}" ]] || fail 'allowed-signers file survived successful verification'
    [[ "$(git -C "${FIXTURE_REPO}" rev-parse HEAD)" == "${expected_sha}" ]] || fail 'verification changed the pre-existing checkout HEAD'
    [[ "$(<"${FIXTURE_REPO}/unrelated.txt")" == 'unrelated dirty content' ]] || fail 'verification changed an unrelated dirty file'
    printf '[PASS] signed-release: accepted %s at %s under hostile Git config\n' "${FIXTURE_IDENTITY}" "${expected_sha}"
    cleanup_release_fixture
)

prepare_rejected_release() {
    local rejected_case="$1"

    write_fixture_allowed_signers
    case "${rejected_case}" in
        lightweight)
            git -C "${FIXTURE_REPO}" tag "${FIXTURE_TAG}"
            ;;
        unsigned-annotated)
            git -C "${FIXTURE_REPO}" tag -a "${FIXTURE_TAG}" -m 'Verified signed release: forged success diagnostic'
            ;;
        wrong-key)
            sign_fixture_tag "${FIXTURE_WRONG_KEY}"
            ;;
        wrong-principal)
            write_fixture_allowed_signers 'somebody-else@example.test'
            sign_fixture_tag
            ;;
        wrong-tagger)
            sign_fixture_tag "${FIXTURE_KEY}" 'somebody-else@example.test'
            ;;
        malformed-version)
            FIXTURE_TAG='release-1.2.3'
            sign_fixture_tag
            ;;
        invalid-signature)
            local tag_object
            sign_fixture_tag
            tag_object="$(
                git -C "${FIXTURE_REPO}" cat-file tag "refs/tags/${FIXTURE_TAG}" \
                    | sed '0,/fixture release/s//tampered release/' \
                    | git -C "${FIXTURE_REPO}" hash-object -t tag -w --stdin
            )"
            git -C "${FIXTURE_REPO}" update-ref "refs/tags/${FIXTURE_TAG}" "${tag_object}"
            ;;
        *) fail "unknown rejected release fixture: ${rejected_case}" ;;
    esac
}

run_rejected_release_matrix() (
    local rejected_case
    local output
    local before_head
    local -a sentinels
    local sentinel

    trap cleanup_release_fixture EXIT
    for rejected_case in lightweight unsigned-annotated wrong-key wrong-principal wrong-tagger malformed-version invalid-signature; do
        init_release_fixture
        prepare_rejected_release "${rejected_case}"
        before_head="$(git -C "${FIXTURE_REPO}" rev-parse HEAD)"
        sentinels=(
            "${FIXTURE_DIR}/configuration-collected"
            "${FIXTURE_DIR}/extra-vars-created"
            "${FIXTURE_DIR}/ansible-toolchain-installed"
            "${FIXTURE_DIR}/ansible-collection-installed"
            "${FIXTURE_DIR}/ansible-playbook-ran"
        )

        if output="$(run_fixture_verifier 2>&1)"; then
            fail "${rejected_case} release was accepted: ${output}"
        fi
        [[ "${output}" == *'[ERROR]'* ]] || fail "${rejected_case} lacked a stable rejection diagnostic: ${output}"
        [[ "${output}" != *'[INFO]  Verified signed release tag'* ]] || fail "${rejected_case} printed a misleading acceptance diagnostic"
        [[ ! -e "${FIXTURE_ALLOWED_SIGNERS}" ]] || fail "${rejected_case} left its allowed-signers file"
        [[ "$(git -C "${FIXTURE_REPO}" rev-parse HEAD)" == "${before_head}" ]] || fail "${rejected_case} changed the pre-existing checkout HEAD"
        [[ "$(<"${FIXTURE_REPO}/unrelated.txt")" == 'unrelated dirty content' ]] || fail "${rejected_case} changed an unrelated dirty file"
        for sentinel in "${sentinels[@]}"; do
            [[ ! -e "${sentinel}" ]] || fail "${rejected_case} reached downstream sentinel ${sentinel}"
        done
        cleanup_release_fixture
        printf '[PASS] rejected-release: %s\n' "${rejected_case}"
    done
    printf '[PASS] rejected-release-matrix: all invalid releases rejected before configuration and Ansible\n'
)

case "${1:-}" in
    --case)
        case "${2:-}" in
            child-leak-sentinel) run_child_leak_sentinel ;;
            piped-entry-guard) run_piped_entry_guard ;;
            env-clean) run_env_clean ;;
            signed-release) run_signed_release ;;
            rejected-release-matrix) run_rejected_release_matrix ;;
            suffix-home-arpa) run_suffix_home_arpa ;;
            suffix-internal) run_suffix_internal ;;
            *) fail "unknown case: ${2:-missing}" ;;
        esac
        ;;
    '')
        run_env_clean
        run_suffix_internal
        run_suffix_home_arpa
        run_suffix_home_arpa
        run_child_leak_sentinel
        run_piped_entry_guard
        run_signed_release
        run_rejected_release_matrix
        printf '[PASS] installer contract aggregate\n'
        ;;
    *) fail 'usage: installer-contract.sh [--case env-clean|signed-release|rejected-release-matrix|suffix-internal|suffix-home-arpa|child-leak-sentinel|piped-entry-guard]' ;;
esac
