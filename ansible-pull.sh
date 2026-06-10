#!/usr/bin/env bash
# =============================================================================
# Zero-Trust VPS Bootstrap Script (ansible-pull Mode)
# =============================================================================
# Interactive bootstrap for ansible-pull execution from GitHub repository.
# Usage: ./ansible-pull.sh [--force]
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_URL="https://github.com/NikitaS2001/ansible-zero-trust-vps.git"
readonly MARKER_FILE=".ansible_pull_bootstrapped"
readonly PULL_CHECKOUT="/opt/zero-trust-vps-pull"

# shellcheck source=scripts/installer-common.sh
source "${SCRIPT_DIR}/scripts/installer-common.sh"

FORCE_MODE=false
CREATED_PULL_CHECKOUT=false
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

Interactive bootstrap script for ansible-pull deployment from GitHub.

This script:
  1. Validates prerequisites and checks for existing deployment
  2. Prompts for configuration values
  3. Installs python3, pip, ansible, and Ansible collections
  4. Runs ansible-pull with inline inventory and user-provided -e vars
  5. Creates ${MARKER_FILE} marker on success

Options:
  --force    Overwrite existing deployment (skip marker check)

Examples:
  ./ansible-pull.sh
  ./ansible-pull.sh --force

EOF
}

cleanup_on_failure() {
    local exit_code=$?

    if [[ "${exit_code}" -eq 0 ]]; then
        return
    fi
    if [[ "${CREATED_PULL_CHECKOUT}" == "true" ]]; then
        warn "Bootstrap failed. Removing partial ansible-pull checkout at ${PULL_CHECKOUT}."
        rm -rf "${PULL_CHECKOUT}"
    else
        warn "Bootstrap failed. Existing checkout and partial Ansible changes may need manual review."
    fi
}
trap cleanup_on_failure EXIT

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                FORCE_MODE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage."
                ;;
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
}

install_dependencies() {
    info "Installing system dependencies (python3, pip, git)..."
    if ! command -v python3 >/dev/null 2>&1; then
        apt-get update
        apt-get install -y python3 python3-pip git
    elif ! command -v git >/dev/null 2>&1; then
        apt-get update
        apt-get install -y git
    fi

    info "Installing ansible..."
    pip3 install --quiet ansible || error "Failed to install ansible. Check pip permissions."
}

prepare_pull_checkout() {
    info "Preparing ansible-pull checkout at ${PULL_CHECKOUT}..."
    if [[ -d "${PULL_CHECKOUT}/.git" ]]; then
        git -C "${PULL_CHECKOUT}" fetch --quiet origin
    elif [[ -e "${PULL_CHECKOUT}" ]]; then
        error "${PULL_CHECKOUT} exists but is not a git checkout."
    else
        CREATED_PULL_CHECKOUT=true
        git clone --quiet "${REPO_URL}" "${PULL_CHECKOUT}"
    fi

    info "Installing Ansible collections from requirements.yml..."
    ansible-galaxy collection install -r "${PULL_CHECKOUT}/requirements.yml"
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

run_ansible_pull() {
    info "Running ansible-pull from ${REPO_URL}..."
    ansible-pull -U "${REPO_URL}" \
        -d "${PULL_CHECKOUT}" \
        -i inventory/localhost.yml \
        "${EXTRA_VARS[@]}" \
        site.yml
}

print_summary() {
    local summary_ssh_port="${SSH_PORT:-$(read_yaml_scalar_default "${PULL_CHECKOUT}/roles/vps_hardening/defaults/main.yml" ssh_port)}"
    local summary_wg_domain="${WG_INTERNAL_DOMAIN:-$(read_yaml_scalar_default "${PULL_CHECKOUT}/roles/vps_orchestration/defaults/main.yml" wg_internal_domain)}"
    local summary_adguard_domain="${ADGUARD_INTERNAL_DOMAIN:-$(read_yaml_scalar_default "${PULL_CHECKOUT}/roles/vps_orchestration/defaults/main.yml" adguard_internal_domain)}"
    local summary_wg_ui_port
    local summary_adguard_ui_port

    summary_wg_ui_port="$(read_yaml_scalar_default "${PULL_CHECKOUT}/roles/vps_hardening/defaults/main.yml" wg_easy_bootstrap_ui_port)"
    summary_adguard_ui_port="$(read_yaml_scalar_default "${PULL_CHECKOUT}/roles/vps_hardening/defaults/main.yml" adguard_bootstrap_ui_port)"

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

To re-run this bootstrap: ./ansible-pull.sh --force

EOF
}

main() {
    parse_args "$@"
    open_tty
    preflight
    collect_configuration
    install_dependencies
    prepare_pull_checkout
    build_extra_vars
    run_ansible_pull

    info "Creating ${MARKER_FILE} marker..."
    touch "${MARKER_FILE}"
    print_summary
}

main "$@"
