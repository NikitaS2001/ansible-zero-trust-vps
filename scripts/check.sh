#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
readonly VENV_DIR="${ROOT_DIR}/.venv"
declare -a PREPARED_EXAMPLES=()

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
    local entry script arguments
    local -a command
    while IFS= read -r entry || [[ -n ${entry} ]]; do
        script=${entry%%|*}
        arguments=${entry#*|}
        command=("tests/validation/${script}")
        [[ -z ${arguments} ]] || command+=("${arguments}")
        "${command[@]}"
    done <tests/validation/manifest.txt
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
