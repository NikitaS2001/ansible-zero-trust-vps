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

RESOLVED_RELEASE_REF=""
CREATED_INSTALL_ROOT=false
CREATED_REPO_DIR=false
CREATED_VENV_DIR=false
EXTRA_VARS_FILE=""
SSH_PORT=""
WG_PORT=""
ADMIN_USER=""
ADMIN_PASSWORD=""
ADGUARD_PASSWORD=""
INTERNAL_DOMAINS=""
WG_INTERNAL_DOMAIN=""
ADGUARD_INTERNAL_DOMAIN=""
SSH_PUBKEY=""

cleanup_on_failure() {
    local exit_code=$?

    cleanup_extra_vars_file

    if [[ "${exit_code}" -eq 0 ]]; then
        return
    fi

    if [[ "${CREATED_REPO_DIR}" == "true" && "${CREATED_INSTALL_ROOT}" != "true" ]]; then
        warn "Installation failed. Removing partial repository checkout at ${REPO_DIR}."
        rm -rf "${REPO_DIR}"
    fi
    if [[ "${CREATED_VENV_DIR}" == "true" && "${CREATED_INSTALL_ROOT}" != "true" ]]; then
        warn "Installation failed. Removing partial Ansible virtualenv at ${VENV_DIR}."
        rm -rf "${VENV_DIR}"
    fi
    if [[ "${CREATED_INSTALL_ROOT}" == "true" ]]; then
        warn "Installation failed. Removing partial installer state at ${INSTALL_ROOT}."
        rm -rf "${INSTALL_ROOT}"
    fi
}
trap cleanup_on_failure EXIT

cleanup_extra_vars_file() {
    if [[ -n "${EXTRA_VARS_FILE}" && -e "${EXTRA_VARS_FILE}" ]]; then
        rm -f "${EXTRA_VARS_FILE}"
    fi
}

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

read_yaml_scalar_default() {
    local defaults_file="$1"
    local key="$2"

    awk -F: -v key="${key}" '
        $1 == key {
            value = $0
            sub(/^[^:]+:[[:space:]]*/, "", value)
            gsub(/^["'\''"]|["'\''"]$/, "", value)
            print value
            exit
        }
    ' "${defaults_file}"
}

validate_release_source() {
    if [[ -z "${REPO_URL}" || "${REPO_URL}" =~ [[:space:]] || "${REPO_URL}" == -* ]]; then
        error "ZERO_TRUST_REPO_URL must be a non-empty git URL without whitespace."
    fi
    if [[ -z "${RELEASE_REF}" || "${RELEASE_REF}" == -* || ! "${RELEASE_REF}" =~ ^[A-Za-z0-9._/@+-]+$ ]]; then
        error "ZERO_TRUST_RELEASE_REF must be a non-empty git ref using only letters, numbers, '.', '_', '/', '@', '+', or '-'."
    fi
    if [[ "${RELEASE_REF}" == *..* || "${RELEASE_REF}" == *@\{* || "${RELEASE_REF}" == *.lock || "${RELEASE_REF}" == */ || "${RELEASE_REF}" == /* ]]; then
        error "ZERO_TRUST_RELEASE_REF is not a safe git ref: ${RELEASE_REF}"
    fi
}

ensure_install_root() {
    if [[ ! -e "${INSTALL_ROOT}" ]]; then
        mkdir -p "${INSTALL_ROOT}"
        CREATED_INSTALL_ROOT=true
        return
    fi
    if [[ ! -d "${INSTALL_ROOT}" ]]; then
        error "${INSTALL_ROOT} exists but is not a directory."
    fi
}

install_prerequisites() {
    info "Installing system prerequisites..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates git python3 python3-venv
}

install_ansible_toolchain() {
    info "Installing Ansible in ${VENV_DIR}..."
    ensure_install_root
    if [[ ! -e "${VENV_DIR}" ]]; then
        CREATED_VENV_DIR=true
    fi
    python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install --quiet ansible "passlib[bcrypt]"
}

checkout_release() {
    info "Checking out ${REPO_URL} at ${RELEASE_REF}..."
    ensure_install_root
    if [[ -d "${REPO_DIR}/.git" ]]; then
        git -C "${REPO_DIR}" fetch --quiet --tags origin
    elif [[ -e "${REPO_DIR}" ]]; then
        error "${REPO_DIR} exists but is not a git checkout. Remove it or set ZERO_TRUST_REPO_URL/ZERO_TRUST_RELEASE_REF for a clean install."
    else
        CREATED_REPO_DIR=true
        git clone --quiet "${REPO_URL}" "${REPO_DIR}"
    fi

    if git -C "${REPO_DIR}" rev-parse --verify --quiet "${RELEASE_REF}^{commit}" >/dev/null; then
        RESOLVED_RELEASE_REF="${RELEASE_REF}"
    elif git -C "${REPO_DIR}" rev-parse --verify --quiet "origin/${RELEASE_REF}^{commit}" >/dev/null; then
        RESOLVED_RELEASE_REF="origin/${RELEASE_REF}"
    else
        error "Git ref '${RELEASE_REF}' or 'origin/${RELEASE_REF}' was not found in ${REPO_URL}."
    fi
    git -C "${REPO_DIR}" checkout --quiet "${RESOLVED_RELEASE_REF}"
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

json_quote() {
    local value="$1"

    printf '%s' "${value}" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

write_extra_var() {
    local key="$1"
    local value="$2"

    {
        printf '%s: ' "${key}"
        json_quote "${value}"
        printf '\n'
    } >>"${EXTRA_VARS_FILE}"
}

prepare_extra_vars_file() {
    ensure_install_root
    EXTRA_VARS_FILE="$(mktemp "${INSTALL_ROOT}/extra-vars.XXXXXX.yml")"
    chmod 0600 "${EXTRA_VARS_FILE}"

    write_extra_var ansible_connection local
    write_extra_var vps_orchestration_enable_ufw_after_ufw_docker true
    write_extra_var admin_password "${ADMIN_PASSWORD}"
    write_extra_var adguard_password "${ADGUARD_PASSWORD}"
    write_extra_var vault_admin_ssh_pubkey "${SSH_PUBKEY}"

    if [[ -n "${SSH_PORT}" ]]; then
        write_extra_var ssh_port "${SSH_PORT}"
    fi
    if [[ -n "${WG_PORT}" ]]; then
        write_extra_var wg_port "${WG_PORT}"
        write_extra_var wg_container_port "${WG_PORT}"
    fi
    if [[ -n "${ADMIN_USER}" ]]; then
        write_extra_var admin_user "${ADMIN_USER}"
    fi
    if [[ -n "${WG_INTERNAL_DOMAIN}" ]]; then
        write_extra_var wg_internal_domain "${WG_INTERNAL_DOMAIN}"
    fi
    if [[ -n "${ADGUARD_INTERNAL_DOMAIN}" ]]; then
        write_extra_var adguard_internal_domain "${ADGUARD_INTERNAL_DOMAIN}"
    fi
}

run_ansible_pull() {
    prepare_extra_vars_file

    if [[ "${RESOLVED_RELEASE_REF}" != "${RELEASE_REF}" ]]; then
        info "Running ansible-pull from ${REPO_URL} at ${RELEASE_REF} (resolved to ${RESOLVED_RELEASE_REF})..."
    else
        info "Running ansible-pull from ${REPO_URL} at ${RELEASE_REF}..."
    fi
    "${VENV_DIR}/bin/ansible-pull" \
        -U "${REPO_URL}" \
        -C "${RESOLVED_RELEASE_REF}" \
        -d "${REPO_DIR}" \
        -i inventory/localhost.yml \
        --extra-vars "@${EXTRA_VARS_FILE}" \
        site.yml
    cleanup_extra_vars_file
}

print_summary() {
    local summary_ssh_port="${SSH_PORT:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" ssh_port)}"
    local summary_admin_user="${ADMIN_USER:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" admin_user)}"
    local summary_wg_domain="${WG_INTERNAL_DOMAIN:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_orchestration/defaults/main.yml" wg_internal_domain)}"
    local summary_adguard_domain="${ADGUARD_INTERNAL_DOMAIN:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_orchestration/defaults/main.yml" adguard_internal_domain)}"
    local summary_wg_ui_port
    local summary_adguard_ui_port

    summary_wg_ui_port="$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" wg_easy_bootstrap_ui_port)"
    summary_adguard_ui_port="$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" adguard_bootstrap_ui_port)"

    cat <<EOF

================================================================================
                         DEPLOYMENT COMPLETE
================================================================================

Open SSH tunnels from your workstation to complete first-client setup:

  ssh -p ${summary_ssh_port} -L ${summary_wg_ui_port}:127.0.0.1:${summary_wg_ui_port} ${summary_admin_user}@<vps-ip>
  ssh -p ${summary_ssh_port} -L ${summary_adguard_ui_port}:127.0.0.1:${summary_adguard_ui_port} ${summary_admin_user}@<vps-ip>

Then create the first WireGuard client in wg-easy and connect to the VPN.
After connecting, use the internal domains:

  https://${summary_wg_domain}
  https://${summary_adguard_domain}

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

    validate_release_source
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
