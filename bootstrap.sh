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

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--force]

Interactive bootstrap for local ansible-playbook deployment.

Options:
  --force    Overwrite existing deployment (skip .bootstrapped check)

Examples:
  ./bootstrap.sh              # Normal run
  ./bootstrap.sh --force      # Re-run even if already bootstrapped
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

    if [[ "${exit_code}" -ne 0 ]]; then
        warn "Bootstrap failed. Script-owned marker files were not created; partial Ansible changes may need manual review."
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

run_playbook() {
    info "Running ansible-playbook..."
    if ! ansible-playbook -i inventory/localhost.yml site.yml "${EXTRA_VARS[@]}" --syntax-check; then
        error "Syntax check failed. Aborting deployment."
    fi
    ansible-playbook -i inventory/localhost.yml site.yml "${EXTRA_VARS[@]}"
    info "Playbook completed successfully."
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

To re-run this bootstrap: ./bootstrap.sh --force

EOF
}

main() {
    parse_args "$@"
    open_tty
    preflight
    install_dependencies
    collect_configuration
    build_extra_vars
    run_playbook

    info "Creating ${MARKER_FILE} marker..."
    touch "${MARKER_FILE}"
    print_summary
}

main "$@"
