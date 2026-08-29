#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
readonly VENV_DIR="${ROOT_DIR}/.venv"
declare -a PREPARED_EXAMPLES=()
readonly -a REQUIRED_VALIDATION_MANIFEST=(
    'ansible-runtime.sh|'
    'backup-sandbox.sh|'
    'installer-contract.sh|'
    'secret-installer-contract.sh|'
    'restore-sandbox.sh|'
    'compose-render.sh|'
    'traffic-mode-contract.sh|'
    'hardening-contract.sh|'
    'orchestration-core.sh|'
    'ufw-docker-idempotency.sh|'
    'workflow-contract.sh|--self-test'
    'check-tooling.sh|'
    'qemu-source-contract.sh|'
    'qemu-packet-contract.sh|'
    'sbom-contract.sh|'
)

cleanup_prepared_examples() {
    local path
    for path in "${PREPARED_EXAMPLES[@]}"; do
        rm -f -- "${ROOT_DIR}/${path}"
    done
}

trap cleanup_prepared_examples EXIT

usage() {
    cat <<EOF
Usage: ${0##*/} [--e2e|--release]

Run repository checks. With no option, run the fast local and CI checks.

Options:
  --e2e      Run fast checks, then the supported-platform QEMU install test.
  --release  Run fast checks, QEMU install and upgrade tests, and release contracts.
  -h, --help Show this help and exit.
EOF
}

mode=quick
case "${1:-}" in
    '') ;;
    --e2e) mode=e2e ;;
    --release) mode=release ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

if [[ -d ${VENV_DIR} ]]; then
    PATH="${VENV_DIR}/bin:${PATH}"
    export PATH
fi

require() {
    command -v "$1" >/dev/null || {
        printf 'check: missing %s; run scripts/bootstrap.sh\n' "$1" >&2
        exit 1
    }
}

prepare_examples() {
    local source destination
    while IFS='|' read -r source destination; do
        if [[ ! -e ${ROOT_DIR}/${destination} ]]; then
            cp "${ROOT_DIR}/${source}" "${ROOT_DIR}/${destination}"
            PREPARED_EXAMPLES+=("${destination}")
        fi
    done <<'EOF'
inventory/hosts.yml.example|inventory/hosts.yml
group_vars/all/vars.yml.example|group_vars/all/vars.yml
group_vars/all/vault_services.yml.example|group_vars/all/vault_services.yml
group_vars/all/vault_ssh.yml.example|group_vars/all/vault_ssh.yml
EOF
}

run_validation_manifest() {
    local expected_entry count entry script arguments
    local -a command
    for expected_entry in "${REQUIRED_VALIDATION_MANIFEST[@]}"; do
        count="$(awk -v expected_entry="${expected_entry}" \
            '$0 == expected_entry { count++ } END { print count + 0 }' \
            tests/validation/manifest.txt)"
        case ${count} in
            0)
                printf 'check: missing required validation manifest entry: %s\n' "${expected_entry}" >&2
                return 1
                ;;
            1) ;;
            *)
                printf 'check: duplicate required validation manifest entry: %s\n' "${expected_entry}" >&2
                return 1
                ;;
        esac
    done

    count="$(awk 'END { print NR + 0 }' tests/validation/manifest.txt)"
    if [[ ${count} -ne ${#REQUIRED_VALIDATION_MANIFEST[@]} ]]; then
        printf 'check: validation manifest must contain exactly %s entries (found %s)\n' \
            "${#REQUIRED_VALIDATION_MANIFEST[@]}" "${count}" >&2
        return 1
    fi

    while IFS= read -r -u 3 entry || [[ -n ${entry} ]]; do
        script=${entry%%|*}
        arguments=${entry#*|}
        command=("tests/validation/${script}")
        [[ -z ${arguments} ]] || command+=("${arguments}")
        "${command[@]}"
    done 3<tests/validation/manifest.txt
}

run_quick() {
    require ansible-playbook
    require ansible-lint
    require yamllint
    require shellcheck
    require python3
    require pre-commit

    prepare_examples
    (
        cd "${ROOT_DIR}"
        bash -n install.sh scripts/*.sh tests/validation/*.sh tests/e2e/*.sh
        shellcheck install.sh scripts/*.sh tests/validation/*.sh tests/e2e/*.sh
        ansible-playbook --syntax-check site.yml
        ansible-lint --strict
        yamllint .
        pre-commit run gitleaks --all-files
        scripts/verify-ssot.sh
        run_validation_manifest
        tests/validation/workflow-contract.sh
    )
}

run_e2e() {
    require qemu-system-x86_64
    require qemu-img
    require genisoimage
    (
        cd "${ROOT_DIR}"
        ZERO_TRUST_WG_TRAFFIC_MODE=services_only \
            tests/e2e/qemu-install.sh --client-test --idempotency-test --reboot-test
    )
}

run_release_contracts() {
    local contract
    for contract in \
        release-artifacts-contract.sh \
        release-workflow-contract.sh \
        release-publish-contract.sh \
        sbom-contract.sh \
        release-contract.sh; do
        "tests/validation/${contract}"
    done
    scripts/release-contract.sh --pr
}

run_quick
case ${mode} in
    quick) ;;
    e2e) run_e2e ;;
    release)
        run_e2e
        (
            cd "${ROOT_DIR}"
            E2E_ARTIFACT_DIR="${TMPDIR:-/tmp}/ztvps-lifecycle-evidence.$(date -u +%Y%m%dT%H%M%SZ)" \
                tests/e2e/lifecycle-qemu.sh
            run_release_contracts
        )
        ;;
esac

printf 'check: %s PASS\n' "${mode}"
