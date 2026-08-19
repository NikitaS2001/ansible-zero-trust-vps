#!/usr/bin/env bash
# Public installer for ansible-zero-trust-vps.
# Intended usage:
#   curl -fsSL https://raw.githubusercontent.com/NikitaS2001/ansible-zero-trust-vps/v1.2.1/install.sh | sudo bash

set -euo pipefail

readonly REPO_URL="${ZERO_TRUST_REPO_URL:-https://github.com/NikitaS2001/ansible-zero-trust-vps.git}"
readonly RELEASE_REF="${ZERO_TRUST_RELEASE_REF:-v1.2.1}"
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
WG_PASSWORD=""
WG_HOST=""
WG_ENABLE_IPV6=""
INTERNAL_DOMAIN_SUFFIX=""
NONINTERACTIVE=""
INHERITED_ADMIN_PASSWORD=""
INHERITED_ADGUARD_PASSWORD=""
INHERITED_WG_PASSWORD=""
INHERITED_SSH_PUBKEY=""

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

Non-interactive mode for automated testing:
  ZERO_TRUST_NONINTERACTIVE=1  Run without prompts; all inputs must be
                               provided via the ZERO_TRUST_* variables below.
  ZERO_TRUST_SSH_PORT          Hardened SSH port (optional, default from role)
  ZERO_TRUST_WG_PORT           WireGuard UDP port (optional, default from role)
  ZERO_TRUST_ADMIN_USER        Admin username (optional, default from role)
  ZERO_TRUST_ADMIN_PASSWORD    Admin password (required, min 8 chars)
  ZERO_TRUST_ADGUARD_PASSWORD  AdGuard admin password (required, min 8 chars)
  ZERO_TRUST_WG_PASSWORD       WireGuard panel password (required, min 8 chars)
  ZERO_TRUST_INTERNAL_DOMAINS  Two internal hostnames, space separated
  ZERO_TRUST_INTERNAL_DOMAIN_SUFFIX  Local DNS suffix for the internal domains
                               (optional, default internal; recommended
                               .internal or .home.arpa)
  ZERO_TRUST_SSH_PUBKEY        SSH public key for the admin user (required)
  ZERO_TRUST_WG_HOST           Public hostname/IP for clients (optional,
                               auto-detected when omitted)
  ZERO_TRUST_WG_ENABLE_IPV6    Enable IPv6 in the VPN stack (true/false,
                               optional, default false; requires a host with
                               IPv6 connectivity)

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

prompt_yesno() {
    local __var_name="$1"
    local prompt_text="$2"
    local value

    printf "%s [y/N]: " "${prompt_text}" >&3
    IFS= read -r value <&3
    case "${value,,}" in
        y | yes) printf -v "${__var_name}" 'true' ;;
        *) printf -v "${__var_name}" 'false' ;;
    esac
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

validate_internal_domain_suffix() {
    local suffix="$1"
    local domains="$2"

    if [[ -z "${suffix}" ]]; then
        return 0
    fi
    validate_hostname "${suffix}" || error "Invalid internal domain suffix: ${suffix}"
    if [[ -n "${domains}" ]]; then
        local -a internal_domains
        read -r -a internal_domains <<<"${domains}"
        local d
        for d in "${internal_domains[@]}"; do
            if [[ "${d}" != *".${suffix}" ]]; then
                error "Internal domain '${d}' does not end with the configured suffix '.${suffix}'."
            fi
        done
    fi
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
    # Pin the Ansible release that the playbook was validated against, so a
    # Pin Ansible to a version that supports Python 3.11 (Debian 12) as well as
    # Python 3.12 (Ubuntu 24.04): ansible >= 13 requires Python >= 3.12, which
    # breaks the public installer on Debian 12. Also pin bcrypt: passlib 1.7.4
    # is incompatible with bcrypt >= 4.1 (removed __about__), which makes the
    # AdGuard bcrypt hash fail with a bogus 72-byte error.
    "${VENV_DIR}/bin/pip" install --quiet "ansible==12.3.0" "passlib[bcrypt]" "bcrypt<4.1"
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
    # --force: requirements.yml pins exact versions, and without --force an
    # already-installed older satisfying version would be kept forever.
    "${VENV_DIR}/bin/ansible-galaxy" collection install -r "${REPO_DIR}/requirements.yml" --force
}

collect_configuration() {
    if [[ "${NONINTERACTIVE}" == "1" ]]; then
        collect_configuration_noninteractive
        return
    fi

    info "Starting interactive configuration..."
    prompt_optional SSH_PORT "SSH port"
    prompt_optional WG_PORT "WireGuard port"
    prompt_optional ADMIN_USER "Admin username"
    prompt_required_secret ADMIN_PASSWORD "Admin password (min 8 chars)"
    prompt_required_secret ADGUARD_PASSWORD "AdGuard admin password (min 8 chars)"
    prompt_required_secret WG_PASSWORD "WireGuard panel password (min 12 chars)"
    prompt_optional INTERNAL_DOMAINS "Internal domains, separated by space"
    prompt_optional INTERNAL_DOMAIN_SUFFIX "Internal domain suffix (Enter for role default: internal)"
    prompt_optional WG_HOST "WireGuard public hostname or IP (Enter to auto-detect)"
    prompt_yesno WG_ENABLE_IPV6 "Enable IPv6 in the VPN stack"
    prompt_required_line SSH_PUBKEY "SSH public key"

    require_max_length "${ADGUARD_PASSWORD}" "AdGuard admin password" 72
    # wg-easy v15 requires at least 12 characters for the panel password at login.
    require_min_length "${WG_PASSWORD}" "WireGuard panel password" 12

    validate_port "SSH port" "${SSH_PORT}"
    validate_port "WireGuard port" "${WG_PORT}"
    validate_optional_admin_user "${ADMIN_USER}"
    validate_internal_domains "${INTERNAL_DOMAINS}"
    validate_internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}" "${INTERNAL_DOMAINS}"
    validate_ssh_pubkey "${SSH_PUBKEY}"
    if [[ -n "${WG_HOST}" ]] && ! validate_hostname "${WG_HOST}"; then
        error "Invalid public hostname or IP for WireGuard clients: ${WG_HOST}"
    fi
}

require_min_length() {
    local value="$1"
    local label="$2"
    local min="${3:-8}"

    if [[ "${#value}" -lt "${min}" ]]; then
        error "${label} must be at least ${min} characters."
    fi
}

require_max_length() {
    local value="$1"
    local label="$2"
    local max="$3"

    if [[ "${#value}" -gt "${max}" ]]; then
        error "${label} must be at most ${max} characters (bcrypt limit)."
    fi
}

detect_public_ip() {
    local ip=""

    ip="$(curl -fsS --max-time 10 -4 https://api.ipify.org 2>/dev/null)" || ip=""
    if [[ -z "${ip}" ]]; then
        ip="$(curl -fsS --max-time 10 -4 https://ifconfig.me 2>/dev/null)" || ip=""
    fi
    if [[ -z "${ip}" ]]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    fi
    printf '%s' "${ip}"
}

collect_configuration_noninteractive() {
    SSH_PORT="${ZERO_TRUST_SSH_PORT:-}"
    WG_PORT="${ZERO_TRUST_WG_PORT:-}"
    ADMIN_USER="${ZERO_TRUST_ADMIN_USER:-}"
    ADMIN_PASSWORD="${INHERITED_ADMIN_PASSWORD}"
    ADGUARD_PASSWORD="${INHERITED_ADGUARD_PASSWORD}"
    WG_PASSWORD="${INHERITED_WG_PASSWORD}"
    INTERNAL_DOMAINS="${ZERO_TRUST_INTERNAL_DOMAINS:-}"
    INTERNAL_DOMAIN_SUFFIX="${ZERO_TRUST_INTERNAL_DOMAIN_SUFFIX:-}"
    SSH_PUBKEY="${INHERITED_SSH_PUBKEY}"
    WG_HOST="${ZERO_TRUST_WG_HOST:-}"
    WG_ENABLE_IPV6="${ZERO_TRUST_WG_ENABLE_IPV6:-}"

    local missing=""
    local var
    for var in ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY; do
        if [[ -z "${!var}" ]]; then
            missing="${missing} ZERO_TRUST_${var}"
        fi
    done
    if [[ -n "${missing}" ]]; then
        error "Non-interactive mode requires the following environment variables:${missing}"
    fi

    require_min_length "${ADMIN_PASSWORD}" "Admin password"
    require_min_length "${ADGUARD_PASSWORD}" "AdGuard admin password"
    require_max_length "${ADGUARD_PASSWORD}" "AdGuard admin password" 72
    # wg-easy v15 requires at least 12 characters for the panel password at login.
    require_min_length "${WG_PASSWORD}" "WireGuard panel password" 12

    validate_port "SSH port" "${SSH_PORT}"
    validate_port "WireGuard port" "${WG_PORT}"
    validate_optional_admin_user "${ADMIN_USER}"
    validate_internal_domains "${INTERNAL_DOMAINS}"
    validate_internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}" "${INTERNAL_DOMAINS}"
    validate_ssh_pubkey "${SSH_PUBKEY}"
    if [[ -n "${WG_HOST}" ]] && ! validate_hostname "${WG_HOST}"; then
        error "Invalid public hostname or IP for WireGuard clients: ${WG_HOST}"
    fi
}

resolve_wg_host() {
    if [[ -n "${WG_HOST}" ]]; then
        return
    fi
    info "Detecting the public IP for WireGuard clients..."
    WG_HOST="$(detect_public_ip)"
    if [[ -z "${WG_HOST}" ]]; then
        if [[ "${NONINTERACTIVE}" == "1" ]]; then
            error "Could not auto-detect the public IP. Set ZERO_TRUST_WG_HOST."
        fi
        prompt_required_line WG_HOST "WireGuard public hostname or IP"
    fi
    info "Using ${WG_HOST} as the WireGuard endpoint host."
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
    write_extra_var vps_orchestration_enable_ufw_before_ufw_docker true
    write_extra_var admin_password "${ADMIN_PASSWORD}"
    write_extra_var adguard_password "${ADGUARD_PASSWORD}"
    write_extra_var wg_easy_admin_password "${WG_PASSWORD}"
    write_extra_var wg_public_host "${WG_HOST}"
    write_extra_var vault_admin_ssh_pubkey "${SSH_PUBKEY}"

    # The secrets were just written to the 0600 extra-vars file; drop them from
    # the environment so child processes (ansible-pull, git) cannot see them.
    unset ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY
    unset INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY

    if [[ -n "${SSH_PORT}" ]]; then
        write_extra_var ssh_port "${SSH_PORT}"
    fi
    if [[ -n "${WG_PORT}" ]]; then
        write_extra_var wg_port "${WG_PORT}"
        write_extra_var wg_container_port "${WG_PORT}"
    fi
    if [[ -n "${WG_ENABLE_IPV6}" ]]; then
        case "${WG_ENABLE_IPV6,,}" in
            y | yes | 1 | true) write_extra_var wg_enable_ipv6 true ;;
            *) write_extra_var wg_enable_ipv6 false ;;
        esac
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
    if [[ -n "${INTERNAL_DOMAIN_SUFFIX}" ]]; then
        write_extra_var internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}"
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
    local summary_domain_suffix="${INTERNAL_DOMAIN_SUFFIX:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_orchestration/defaults/main.yml" internal_domain_suffix)}"
    local summary_wg_domain="${WG_INTERNAL_DOMAIN:-wg.${summary_domain_suffix}}"
    local summary_adguard_domain="${ADGUARD_INTERNAL_DOMAIN:-adguard.${summary_domain_suffix}}"
    local summary_wg_ui_port
    local summary_adguard_ui_port
    local summary_wg_port="${WG_PORT:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_orchestration/defaults/main.yml" wg_port)}"
    local summary_wg_host="${WG_HOST:-<vps-ip>}"

    summary_wg_ui_port="$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" wg_easy_bootstrap_ui_port)"
    summary_adguard_ui_port="$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" adguard_bootstrap_ui_port)"

    cat <<EOF

================================================================================
                         DEPLOYMENT COMPLETE
================================================================================

Open an SSH tunnel to reach the wg-easy panel and finish first-client setup:

  ssh -p ${summary_ssh_port} -L ${summary_wg_ui_port}:127.0.0.1:${summary_wg_ui_port} ${summary_admin_user}@<vps-ip>

Then log in to http://127.0.0.1:${summary_wg_ui_port} with the WireGuard panel
password you entered during installation, create a client, and connect.

  VPN endpoint for clients: ${summary_wg_host}:${summary_wg_port} (UDP)

For AdGuard, use the second tunnel when needed:

  ssh -p ${summary_ssh_port} -L ${summary_adguard_ui_port}:127.0.0.1:${summary_adguard_ui_port} ${summary_admin_user}@<vps-ip>

After connecting to the VPN, use the internal domains:

  https://${summary_wg_domain}
  https://${summary_adguard_domain}

================================================================================

EOF
}

main() {
    export -n ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY 2>/dev/null || true
    export -n INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY 2>/dev/null || true
    INHERITED_ADMIN_PASSWORD="${ZERO_TRUST_ADMIN_PASSWORD:-}"
    INHERITED_ADGUARD_PASSWORD="${ZERO_TRUST_ADGUARD_PASSWORD:-}"
    INHERITED_WG_PASSWORD="${ZERO_TRUST_WG_PASSWORD:-}"
    INHERITED_SSH_PUBKEY="${ZERO_TRUST_SSH_PUBKEY:-}"
    export -n ZERO_TRUST_ADMIN_PASSWORD ZERO_TRUST_ADGUARD_PASSWORD ZERO_TRUST_WG_PASSWORD ZERO_TRUST_SSH_PUBKEY 2>/dev/null || true
    unset ZERO_TRUST_ADMIN_PASSWORD ZERO_TRUST_ADGUARD_PASSWORD ZERO_TRUST_WG_PASSWORD ZERO_TRUST_SSH_PUBKEY

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    if [[ $# -gt 0 ]]; then
        error "Unknown option: $1. Use --help for usage."
    fi

    NONINTERACTIVE="${ZERO_TRUST_NONINTERACTIVE:-0}"

    # A fresh Debian/Ubuntu VPS usually only has C.UTF-8 generated, while the
    # SSH session forwards the caller's locale (e.g. ru_RU.UTF-8). Ansible
    # aborts with "unsupported locale setting" in that case, so pin a safe
    # locale for the toolchain and ansible-pull steps.
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8

    validate_release_source
    require_root
    require_supported_os
    if [[ "${NONINTERACTIVE}" != "1" ]]; then
        open_tty
    fi
    collect_configuration
    resolve_wg_host
    install_prerequisites
    install_ansible_toolchain
    checkout_release
    install_collections
    run_ansible_pull
    print_summary
}

# curl | bash leaves BASH_SOURCE unset; ${parameter:-$0} still invokes main.
# Sourcing the file keeps BASH_SOURCE different from $0, so tests can stub main.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
