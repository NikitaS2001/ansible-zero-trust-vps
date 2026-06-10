#!/usr/bin/env bash
# =============================================================================
# Zero-Trust VPS Bootstrap Script (Local Execution)
# =============================================================================
# Usage: ./bootstrap.sh [--force]
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT
readonly MARKER_FILE="${REPO_ROOT}/.bootstrapped"

# shellcheck source=scripts/installer-common.sh
source "${REPO_ROOT}/scripts/installer-common.sh"

FORCE_MODE=false
SSH_PORT=""
WG_PORT=""
ADMIN_USER=""
ADMIN_PASSWORD=""
ADGUARD_PASSWORD=""
INTERNAL_DOMAINS=""
WG_INTERNAL_DOMAIN=""
ADGUARD_INTERNAL_DOMAIN=""
SSH_PUBKEY=""
EXTRA_VARS=()

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--force]

Interactive bootstrap for local ansible-playbook deployment.

Options:
  --force    Overwrite existing deployment (skip .bootstrapped check)

Examples:
  ./bootstrap.sh
  ./bootstrap.sh --force
EOF
}

cleanup_on_failure() {
    local exit_code=$?

    if [[ "${exit_code}" -ne 0 ]]; then
        warn "Bootstrap failed. Script-owned marker files were not created; partial Ansible changes may need manual review."
    fi
}
trap cleanup_on_failure EXIT

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) FORCE_MODE=true; shift ;;
            --help|-h) usage; exit 0 ;;
            *) error "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

preflight() {
    info "Running pre-flight checks..."
    if [[ -f "${MARKER_FILE}" ]]; then
        if [[ "${FORCE_MODE}" == "false" ]]; then
            warn "Deployment detected. Found: ${MARKER_FILE}"
            error "Run with --force to overwrite, or remove this file first."
        fi
        warn "Overwriting existing deployment (--force mode)..."
    fi
    if [[ ! -f "${REPO_ROOT}/site.yml" ]]; then
        error "site.yml not found. Are you running from the repository root?"
    fi
}

install_dependencies() {
    info "Installing system dependencies (python3, pip)..."
    if ! command -v python3 >/dev/null 2>&1; then
        apt-get update
        apt-get install -y python3 python3-pip
    fi

    info "Installing ansible..."
    pip3 install --quiet ansible || error "Failed to install ansible. Check pip permissions."

    info "Installing Ansible collections from requirements.yml..."
    ansible-galaxy collection install -r "${REPO_ROOT}/requirements.yml"
}

build_extra_vars() {
    EXTRA_VARS=(
        -e "ansible_connection=local"
        -e "admin_password=${ADMIN_PASSWORD}"
        -e "adguard_password=${ADGUARD_PASSWORD}"
        -e "vault_admin_ssh_pubkey=${SSH_PUBKEY}"
    )
    append_user_extra_vars
}

run_playbook() {
    info "Running ansible-playbook..."
    if ! ansible-playbook -i inventory/localhost.yml site.yml "${EXTRA_VARS[@]}" --syntax-check; then
        error "Syntax check failed. Aborting deployment."
    fi
    ansible-playbook -i inventory/localhost.yml site.yml "${EXTRA_VARS[@]}"
    info "Playbook completed successfully."
}

print_summary() {
    local summary_ssh_port="${SSH_PORT:-$(read_yaml_scalar_default "${REPO_ROOT}/roles/vps_hardening/defaults/main.yml" ssh_port)}"
    local summary_wg_domain="${WG_INTERNAL_DOMAIN:-$(read_yaml_scalar_default "${REPO_ROOT}/roles/vps_orchestration/defaults/main.yml" wg_internal_domain)}"
    local summary_adguard_domain="${ADGUARD_INTERNAL_DOMAIN:-$(read_yaml_scalar_default "${REPO_ROOT}/roles/vps_orchestration/defaults/main.yml" adguard_internal_domain)}"
    local summary_wg_ui_port
    local summary_adguard_ui_port

    summary_wg_ui_port="$(read_yaml_scalar_default "${REPO_ROOT}/roles/vps_hardening/defaults/main.yml" wg_easy_bootstrap_ui_port)"
    summary_adguard_ui_port="$(read_yaml_scalar_default "${REPO_ROOT}/roles/vps_hardening/defaults/main.yml" adguard_bootstrap_ui_port)"

    cat <<EOF

================================================================================
                         DEPLOYMENT COMPLETE
================================================================================

Access your services via SSH tunnels:

  # wg-easy (WireGuard UI) - complete setup wizard here first
  ssh -p ${summary_ssh_port} -L ${summary_wg_ui_port}:127.0.0.1:${summary_wg_ui_port} localhost

  # AdGuard Home admin UI
  ssh -p ${summary_ssh_port} -L ${summary_adguard_ui_port}:127.0.0.1:${summary_adguard_ui_port} localhost

  # After connecting via WireGuard, access internal domains:
  #   https://${summary_wg_domain}
  #   https://${summary_adguard_domain}

================================================================================

To re-run this bootstrap: ./bootstrap.sh --force

EOF
}

main() {
    parse_args "$@"
    open_tty
    preflight
    collect_configuration
    install_dependencies
    build_extra_vars
    run_playbook

    info "Creating ${MARKER_FILE} marker..."
    touch "${MARKER_FILE}"
    print_summary
}

main "$@"
