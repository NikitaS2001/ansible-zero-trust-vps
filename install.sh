#!/usr/bin/env bash
# Public installer for ansible-zero-trust-vps.
# Intended usage:
#   curl -fsSL https://raw.githubusercontent.com/NikitaS2001/ansible-zero-trust-vps/v1.0.0/install.sh | sudo bash

set -euo pipefail

readonly REPO_URL="${ZERO_TRUST_REPO_URL:-https://github.com/NikitaS2001/ansible-zero-trust-vps.git}"
readonly RELEASE_REF="${ZERO_TRUST_RELEASE_REF:-v1.0.0}"
readonly INSTALL_ROOT="/opt/zero-trust-vps-installer"
readonly REPO_DIR="${INSTALL_ROOT}/repo"
readonly VENV_DIR="${INSTALL_ROOT}/venv"

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
Usage: install.sh

Interactive public installer for ansible-zero-trust-vps.

Environment overrides for release testing:
  ZERO_TRUST_REPO_URL      Repository URL to pull from
  ZERO_TRUST_RELEASE_REF  Git tag or ref to install

The public quickstart should use the tagged script URL, not main.
EOF
}

info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
error() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "Run this installer as root, for example: curl -fsSL .../install.sh | sudo bash"
    fi
}

require_supported_os() {
    if [[ ! -r /etc/os-release ]]; then
        error "/etc/os-release not found. This installer supports Debian/Ubuntu systems."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            ;;
        *)
            error "Unsupported OS '${ID:-unknown}'. This installer supports Debian/Ubuntu systems."
            ;;
    esac

    command -v apt-get >/dev/null 2>&1 || error "apt-get not found. This installer supports apt-based systems."
}

open_tty() {
    if [[ ! -r /dev/tty ]]; then
        error "Interactive installation requires a TTY. SSH into the VPS and run the installer from a terminal."
    fi
    exec 3<>/dev/tty
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

    while true; do
        printf "%s: " "${prompt_text}" >&3
        IFS= read -r -s value <&3
        printf "\n" >&3
        if [[ "${#value}" -lt 8 ]]; then
            warn "Value must be at least 8 characters."
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
    if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1024 ]] || [[ "${value}" -gt 65535 ]]; then
        error "${label} must be a number between 1024 and 65535. Got: ${value}"
    fi
}

validate_optional_admin_user() {
    local value="$1"

    if [[ -z "${value}" ]]; then
        return 0
    fi
    if ! [[ "${value}" =~ ^[a-z0-9]+$ ]]; then
        error "Admin username must be lowercase alphanumeric. Got: ${value}"
    fi
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

    WG_INTERNAL_DOMAIN="${internal_domains[0]}"
    ADGUARD_INTERNAL_DOMAIN="${internal_domains[1]}"
}

validate_ssh_pubkey() {
    local value="$1"

    if ! [[ "${value}" =~ ^(ssh-|ecdsa-) ]]; then
        error "SSH public key must start with 'ssh-' or 'ecdsa-'. Got: ${value:0:20}..."
    fi
}

install_prerequisites() {
    info "Installing system prerequisites..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates git python3 python3-venv >/dev/null
}

install_ansible_toolchain() {
    info "Installing Ansible in ${VENV_DIR}..."
    mkdir -p "${INSTALL_ROOT}"
    python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install --quiet ansible
}

checkout_release() {
    info "Checking out ${REPO_URL} at ${RELEASE_REF}..."
    mkdir -p "${INSTALL_ROOT}"
    if [[ -d "${REPO_DIR}/.git" ]]; then
        git -C "${REPO_DIR}" fetch --quiet --tags origin
    else
        git clone --quiet "${REPO_URL}" "${REPO_DIR}"
    fi
    git -C "${REPO_DIR}" checkout --quiet "${RELEASE_REF}"
}

install_collections() {
    info "Installing Ansible collections from requirements.yml..."
    "${VENV_DIR}/bin/ansible-galaxy" collection install -r "${REPO_DIR}/requirements.yml"
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

run_ansible_pull() {
    local -a extra_vars
    extra_vars=(
        -e "ansible_connection=local"
        -e "admin_password=${ADMIN_PASSWORD}"
        -e "adguard_password=${ADGUARD_PASSWORD}"
        -e "vault_admin_ssh_pubkey=${SSH_PUBKEY}"
    )

    if [[ -n "${SSH_PORT}" ]]; then
        extra_vars+=(-e "ssh_port=${SSH_PORT}")
    fi
    if [[ -n "${WG_PORT}" ]]; then
        extra_vars+=(-e "wg_port=${WG_PORT}" -e "wg_container_port=${WG_PORT}")
    fi
    if [[ -n "${ADMIN_USER}" ]]; then
        extra_vars+=(-e "admin_user=${ADMIN_USER}")
    fi
    if [[ -n "${WG_INTERNAL_DOMAIN}" ]]; then
        extra_vars+=(-e "wg_internal_domain=${WG_INTERNAL_DOMAIN}")
    fi
    if [[ -n "${ADGUARD_INTERNAL_DOMAIN}" ]]; then
        extra_vars+=(-e "adguard_internal_domain=${ADGUARD_INTERNAL_DOMAIN}")
    fi

    info "Running ansible-pull from ${REPO_URL} at ${RELEASE_REF}..."
    "${VENV_DIR}/bin/ansible-pull" \
        -U "${REPO_URL}" \
        -C "${RELEASE_REF}" \
        -d "${REPO_DIR}" \
        -i inventory/localhost.yml \
        "${extra_vars[@]}" \
        site.yml
}

print_summary() {
    cat <<EOF

================================================================================
                         DEPLOYMENT COMPLETE
================================================================================

Open SSH tunnels from your workstation to complete first-client setup:

  ssh -p <ssh_port> -L <local-port>:127.0.0.1:<remote-ui-port> <admin-user>@<vps-ip>

Then create the first WireGuard client in wg-easy and connect to the VPN.

================================================================================

EOF
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    if [[ $# -gt 0 ]]; then
        error "Unknown option: $1. Use --help for usage."
    fi

    require_root
    require_supported_os
    open_tty
    collect_configuration
    install_prerequisites
    install_ansible_toolchain
    checkout_release
    install_collections
    run_ansible_pull
    print_summary
}

main "$@"
