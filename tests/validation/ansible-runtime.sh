#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASE_NAME="all"
TMP_DIR=""
PLAYBOOK_DIR=""
INVENTORY_FILE=""
PLAYBOOK_FILE=""

usage() {
    cat <<'EOF'
Usage: tests/validation/ansible-runtime.sh [--case matching|mismatch|isolation]

Runs only the tagged orchestration internal-domain preflight against localhost.
EOF
}

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --case)
            [[ $# -ge 2 ]] || fail '--case requires matching or mismatch'
            CASE_NAME="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

case "${CASE_NAME}" in
    all|matching|mismatch|isolation) ;;
    *) fail "unknown case: ${CASE_NAME}" ;;
esac

command -v ansible-playbook >/dev/null || fail 'ansible-playbook is required'
cd "${ROOT_DIR}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ansible-runtime.XXXXXX")"
PLAYBOOK_DIR="${TMP_DIR}/playbook"
INVENTORY_FILE="${PLAYBOOK_DIR}/inventory.yml"
PLAYBOOK_FILE="${PLAYBOOK_DIR}/site.yml"

mkdir -p "${PLAYBOOK_DIR}"
printf '%s\n' \
    '---' \
    'all:' \
    '  children:' \
    '    vps:' \
    '      hosts:' \
    '        localhost:' \
    '          ansible_connection: local' >"${INVENTORY_FILE}"
printf '%s\n' \
    '---' \
    '- name: Runtime preflight isolation' \
    '  hosts: vps' \
    '  gather_facts: false' \
    '  become: false' \
    '  roles:' \
    "    - role: ${ROOT_DIR}/roles/vps_orchestration" \
    '      tags: [orchestration]' >"${PLAYBOOK_FILE}"

create_isolation_fixture() {
    local fixture_dir="${TMP_DIR}/unrelated-group-vars/group_vars/all"
    local fixture_tmp="${fixture_dir}/unrelated.yml.tmp"

    mkdir -p "${fixture_dir}"
    printf '%s\n' \
        "\$ANSIBLE_VAULT;1.1;AES256" \
        '0000000000000000000000000000000000000000000000000000000000000000' >"${fixture_tmp}"
    mv -- "${fixture_tmp}" "${fixture_dir}/unrelated.yml"
}

run_case() {
    local case_name="$1"
    local wg_domain="wg.internal"
    local adguard_domain="adguard.internal"
    local expected_rc=0
    local log_file
    local rc

    if [[ "${case_name}" == "mismatch" ]]; then
        wg_domain="wg.example"
        expected_rc=1
    elif [[ "${case_name}" == "isolation" ]]; then
        create_isolation_fixture
    fi

    log_file="${TMP_DIR}/${case_name}.log"

    set +e
    ansible-playbook \
        -i "${INVENTORY_FILE}" \
        --tags orchestration_domain_preflight \
        -e ansible_become=false \
        -e "wg_internal_domain=${wg_domain}" \
        -e "adguard_internal_domain=${adguard_domain}" \
        "${PLAYBOOK_FILE}" >"${log_file}" 2>&1
    rc=$?
    set -e

    if grep -Eq 'unexpected char|Traceback' "${log_file}"; then
        sed -n '1,220p' "${log_file}" >&2
        fail "${case_name} emitted an Ansible parser error or traceback"
    fi

    if [[ "$(grep -Ec '^TASK \[.* : VPS Orchestration \| Preflight \| Internal domains match the configured suffix\]' "${log_file}" || true)" -ne 1 ]]; then
        sed -n '1,220p' "${log_file}" >&2
        fail "${case_name} did not run exactly one real tagged domain preflight"
    fi

    if grep -E '^TASK \[.* : VPS Orchestration \|' "${log_file}" | grep -Fv 'Internal domains match the configured suffix' >/dev/null; then
        sed -n '1,220p' "${log_file}" >&2
        fail "${case_name} ran a later orchestration task"
    fi

    if [[ "${expected_rc}" -eq 0 ]]; then
        [[ "${rc}" -eq 0 ]] || {
            sed -n '1,220p' "${log_file}" >&2
            fail "matching case returned Ansible rc=${rc}, expected 0"
        }
        return
    fi

    [[ "${rc}" -ne 0 ]] || {
        sed -n '1,220p' "${log_file}" >&2
        fail 'mismatch case returned Ansible rc=0, expected nonzero'
    }
    grep -Fq 'must end with' "${log_file}" || {
        sed -n '1,220p' "${log_file}" >&2
        fail 'mismatch case omitted the intended must end with diagnostic'
    }
}

if [[ "${CASE_NAME}" == "all" || "${CASE_NAME}" == "matching" ]]; then
    run_case matching
fi

if [[ "${CASE_NAME}" == "all" || "${CASE_NAME}" == "mismatch" ]]; then
    run_case mismatch
fi

if [[ "${CASE_NAME}" == "isolation" ]]; then
    run_case isolation
    printf '[PASS] isolation: unrelated encrypted group_vars did not affect the real tagged preflight\n'
fi

if [[ "${CASE_NAME}" == "all" ]]; then
    printf '[PASS] matching: real tagged preflight accepted matching domains\n'
    printf '[PASS] mismatch: real tagged preflight rejected wg.example with intended suffix message\n'
fi
