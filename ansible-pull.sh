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
readonly REPO_URL="https://github.com/NikitaS2001/ansible-zero-trust-vps.git"
readonly MARKER_FILE=".ansible_pull_bootstrapped"
readonly PULL_CHECKOUT="/opt/zero-trust-vps-pull"

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

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--force]

Interactive bootstrap script for ansible-pull deployment from GitHub.

This script:
  1. Validates prerequisites and checks for existing deployment
  2. Installs python3, pip, ansible, and Ansible collections
  3. Prompts for configuration values
  4. Runs ansible-pull with inline inventory and user-provided -e vars
  5. Creates ${MARKER_FILE} marker on success

Options:
  --force    Overwrite existing deployment (skip marker check)

Examples:
  ./ansible-pull.sh
  ./ansible-pull.sh --force

EOF
}

info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
error() {
    echo "[ERROR] $*" >&2
    exit 1
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

open_tty() {
    if [[ ! -r /dev/tty ]]; then
        error "Interactive bootstrap requires a TTY. Run this script from a terminal."
    fi
    exec 3<>/dev/tty || error "Failed to open /dev/tty for interactive prompts."
}

prompt_optional() {
    local __var_name="$1"
    local prompt_text="$2"
    local value

    printf "%s (Enter for role default): " "${prompt_text}" >&3
    IFS= read -r value <&3
    printf -v "${__var_name}" '%s' "${value}"
}

prompt_required_secret() {
    local __var_name="$1"
    local prompt_text="$2"
    local value
    local confirmation

    while true; do
        printf "%s: " "${prompt_text}" >&3
        IFS= read -r -s value <&3
        printf "\n" >&3
        if [[ "${#value}" -lt 8 ]]; then
            warn "Value must be at least 8 characters."
            continue
        fi
        printf "Confirm %s: " "${prompt_text}" >&3
        IFS= read -r -s confirmation <&3
        printf "\n" >&3
        if [[ "${value}" != "${confirmation}" ]]; then
            warn "Values did not match. Try again."
            continue
        fi
        printf -v "${__var_name}" '%s' "${value}"
        break
    done
}

prompt_required_line() {
    local __var_name="$1"
    local prompt_text="$2"
    local value

    while true; do
        printf "%s: " "${prompt_text}" >&3
        IFS= read -r value <&3
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ -z "${value}" ]]; then
            warn "Value is required."
            continue
        fi
        printf -v "${__var_name}" '%s' "${value}"
        break
    done
}

validate_port() {
    local label="$1"
    local value="$2"

    if [[ -z "${value}" ]]; then
        return 0
    fi
    if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1 ]] || [[ "${value}" -gt 65535 ]]; then
        error "${label} must be a number between 1 and 65535. Got: ${value}"
    fi
}

validate_optional_admin_user() {
    local value="$1"

    if [[ -z "${value}" ]]; then
        return 0
    fi
    if ! [[ "${value}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "Admin username must be a valid Linux user name. Got: ${value}"
    fi
}

validate_hostname() {
    local value="$1"
    local label
    local -a labels

    if [[ "${#value}" -gt 253 || "${value}" == .* || "${value}" == *. ]]; then
        return 1
    fi
    IFS=. read -r -a labels <<<"${value}"
    for label in "${labels[@]}"; do
        if [[ -z "${label}" || "${#label}" -gt 63 || ! "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
            return 1
        fi
    done
}

validate_internal_domains() {
    local value="$1"
    local -a internal_domains

    WG_INTERNAL_DOMAIN=""
    ADGUARD_INTERNAL_DOMAIN=""

    if [[ -z "${value}" ]]; then
        return 0
    fi

    read -r -a internal_domains <<<"${value}"
    if [[ "${#internal_domains[@]}" -ne 2 ]]; then
        error "Internal domains must be exactly two hostnames, for example: wg.internal adguard.internal"
    fi
    validate_hostname "${internal_domains[0]}" || error "Invalid internal hostname: ${internal_domains[0]}"
    validate_hostname "${internal_domains[1]}" || error "Invalid internal hostname: ${internal_domains[1]}"

    WG_INTERNAL_DOMAIN="${internal_domains[0]}"
    ADGUARD_INTERNAL_DOMAIN="${internal_domains[1]}"
}

validate_ssh_pubkey() {
    local value="$1"
    local key_type
    local key_body

    read -r key_type key_body _ <<<"${value}"
    case "${key_type}" in
        ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            ;;
        *)
            error "Unsupported SSH public key type '${key_type}'. Use an OpenSSH public key, including FIDO/U2F sk-* keys."
            ;;
    esac
    if [[ "${#key_body}" -lt 32 || ! "${key_body}" =~ ^[A-Za-z0-9+/]+={0,3}$ ]]; then
        error "SSH public key body does not look like valid base64."
    fi
}

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

collect_configuration() {
    info "Starting interactive configuration..."
    prompt_optional SSH_PORT "SSH port"
    prompt_optional WG_PORT "WireGuard port"
    prompt_optional ADMIN_USER "Admin username"
    prompt_required_secret ADMIN_PASSWORD "Admin password (min 8 chars)"
    prompt_required_secret ADGUARD_PASSWORD "AdGuard admin password (min 8 chars)"
    prompt_optional INTERNAL_DOMAINS "Internal domains, separated by space"
    prompt_required_line SSH_PUBKEY "SSH public key"

    validate_port "SSH port" "${SSH_PORT}"
    validate_port "WireGuard port" "${WG_PORT}"
    validate_optional_admin_user "${ADMIN_USER}"
    validate_internal_domains "${INTERNAL_DOMAINS}"
    validate_ssh_pubkey "${SSH_PUBKEY}"
}

build_extra_vars() {
    EXTRA_VARS=(
        -e "ansible_connection=local"
        -e "admin_password=${ADMIN_PASSWORD}"
        -e "adguard_password=${ADGUARD_PASSWORD}"
        -e "vault_admin_ssh_pubkey=${SSH_PUBKEY}"
    )

    if [[ -n "${SSH_PORT}" ]]; then
        EXTRA_VARS+=(-e "ssh_port=${SSH_PORT}")
    fi
    if [[ -n "${WG_PORT}" ]]; then
        EXTRA_VARS+=(-e "wg_port=${WG_PORT}" -e "wg_container_port=${WG_PORT}")
    fi
    if [[ -n "${ADMIN_USER}" ]]; then
        EXTRA_VARS+=(-e "admin_user=${ADMIN_USER}")
    fi
    if [[ -n "${WG_INTERNAL_DOMAIN}" ]]; then
        EXTRA_VARS+=(-e "wg_internal_domain=${WG_INTERNAL_DOMAIN}")
    fi
    if [[ -n "${ADGUARD_INTERNAL_DOMAIN}" ]]; then
        EXTRA_VARS+=(-e "adguard_internal_domain=${ADGUARD_INTERNAL_DOMAIN}")
    fi
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
    local summary_ssh_port="${SSH_PORT:-<role default ssh_port>}"
    local summary_wg_domain="${WG_INTERNAL_DOMAIN:-<role default wg_internal_domain>}"
    local summary_adguard_domain="${ADGUARD_INTERNAL_DOMAIN:-<role default adguard_internal_domain>}"

    cat <<EOF

================================================================================
                         DEPLOYMENT COMPLETE
================================================================================

Access your services via SSH tunnels:

  # wg-easy (WireGuard UI) - complete setup wizard here first
  ssh -p ${summary_ssh_port} -L <wg-easy-local-port>:127.0.0.1:<wg-easy-ui-port> localhost

  # AdGuard Home admin UI
  ssh -p ${summary_ssh_port} -L <adguard-local-port>:127.0.0.1:<adguard-ui-port> localhost

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
    install_dependencies
    prepare_pull_checkout
    collect_configuration
    build_extra_vars
    run_ansible_pull

    info "Creating ${MARKER_FILE} marker..."
    touch "${MARKER_FILE}"
    print_summary
}

main "$@"
