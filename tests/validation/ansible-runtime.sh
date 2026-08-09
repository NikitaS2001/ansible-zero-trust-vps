#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASE_NAME="all"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: tests/validation/ansible-runtime.sh [--case matching|mismatch]

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
    all|matching|mismatch) ;;
    *) fail "unknown case: ${CASE_NAME}" ;;
esac

command -v ansible-playbook >/dev/null || fail 'ansible-playbook is required'
cd "${ROOT_DIR}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ansible-runtime.XXXXXX")"

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
    fi

    log_file="${TMP_DIR}/${case_name}.log"

    set +e
    ansible-playbook \
        -i inventory/localhost.yml \
        --tags orchestration_domain_preflight \
        -e ansible_become=false \
        -e "wg_internal_domain=${wg_domain}" \
        -e "adguard_internal_domain=${adguard_domain}" \
        site.yml >"${log_file}" 2>&1
    rc=$?
    set -e

    if grep -Eq 'unexpected char|Traceback' "${log_file}"; then
        sed -n '1,220p' "${log_file}" >&2
        fail "${case_name} emitted an Ansible parser error or traceback"
    fi

    if [[ "$(grep -Ec '^TASK \[vps_orchestration : .*Internal domains match the configured suffix' "${log_file}" || true)" -ne 1 ]]; then
        sed -n '1,220p' "${log_file}" >&2
        fail "${case_name} did not run exactly one real tagged domain preflight"
    fi

    if grep -E '^TASK \[vps_orchestration :' "${log_file}" | grep -Fv 'Internal domains match the configured suffix' >/dev/null; then
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

if [[ "${CASE_NAME}" == "all" ]]; then
    printf '[PASS] matching: real tagged preflight accepted matching domains\n'
    printf '[PASS] mismatch: real tagged preflight rejected wg.example with intended suffix message\n'
fi
