#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2329

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

case "${1:-}" in
    --case)
        case "${2:-}" in
            child-leak-sentinel) run_child_leak_sentinel ;;
            env-clean) run_env_clean ;;
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
        printf '[PASS] installer contract aggregate\n'
        ;;
    *) fail 'usage: installer-contract.sh [--case env-clean|suffix-internal|suffix-home-arpa|child-leak-sentinel]' ;;
esac
