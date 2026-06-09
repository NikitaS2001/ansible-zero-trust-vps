#!/usr/bin/env bash
# =============================================================================
# Zero-Trust VPS Bootstrap Script (Local Execution)
# =============================================================================
# Usage: ./bootstrap.sh [--force]
# =============================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MARKER_FILE="${REPO_ROOT}/.bootstrapped"

DEFAULT_SSH_PORT="2222"
DEFAULT_WG_PORT="51820"
DEFAULT_ADMIN_USER="sysadmin"
DEFAULT_INTERNAL_DOMAINS="wg.internal adguard.internal"

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

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

FORCE_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE_MODE=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) error "Unknown option: $1. Use --help for usage." ;;
    esac
done

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

info "Installing system dependencies (python3, pip)..."
if ! command -v python3 &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip >/dev/null 2>&1 \
        || error "Failed to install python3/pip. Please install manually."
fi

info "Installing ansible and community.docker..."
pip3 install --quiet ansible "community.docker>=4.0.0,<5.0.0" 2>/dev/null \
    || error "Failed to install ansible. Check pip permissions."

info "Starting interactive configuration..."

read -p "SSH port [${DEFAULT_SSH_PORT}]: " SSH_PORT
SSH_PORT="${SSH_PORT:-${DEFAULT_SSH_PORT}}"
if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || [[ "${SSH_PORT}" -lt 1024 ]] || [[ "${SSH_PORT}" -gt 65535 ]]; then
    error "SSH port must be a number between 1024 and 65535. Got: ${SSH_PORT}"
fi

read -p "WireGuard port [${DEFAULT_WG_PORT}]: " WG_PORT
WG_PORT="${WG_PORT:-${DEFAULT_WG_PORT}}"
if ! [[ "${WG_PORT}" =~ ^[0-9]+$ ]] || [[ "${WG_PORT}" -lt 1024 ]] || [[ "${WG_PORT}" -gt 65535 ]]; then
    error "WireGuard port must be a number between 1024 and 65535. Got: ${WG_PORT}"
fi

read -p "Admin username [${DEFAULT_ADMIN_USER}]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-${DEFAULT_ADMIN_USER}}"
if ! [[ "${ADMIN_USER}" =~ ^[a-z0-9]+$ ]]; then
    error "Admin username must be lowercase alphanumeric. Got: ${ADMIN_USER}"
fi

while true; do
    read -s -p "Admin password (min 8 chars): " ADMIN_PASSWORD
    echo
    if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
        warn "Password must be at least 8 characters."
        continue
    fi
    break
done

while true; do
    read -s -p "AdGuard admin password (min 8 chars): " ADGUARD_PASSWORD
    echo
    if [[ ${#ADGUARD_PASSWORD} -lt 8 ]]; then
        warn "Password must be at least 8 characters."
        continue
    fi
    break
done

read -p "Internal domains [${DEFAULT_INTERNAL_DOMAINS}]: " INTERNAL_DOMAINS
INTERNAL_DOMAINS="${INTERNAL_DOMAINS:-${DEFAULT_INTERNAL_DOMAINS}}"
WG_INTERNAL_DOMAIN="$(echo "${INTERNAL_DOMAINS}" | awk '{print $1}')"
ADGUARD_INTERNAL_DOMAIN="$(echo "${INTERNAL_DOMAINS}" | awk '{print $2}')"
if [[ -z "${WG_INTERNAL_DOMAIN}" ]] || [[ -z "${ADGUARD_INTERNAL_DOMAIN}" ]]; then
    error "Need at least 2 domains (e.g. 'wg.internal adguard.internal'). Got: ${INTERNAL_DOMAINS}"
fi

read -p "SSH public key: " SSH_PUBKEY
SSH_PUBKEY="${SSH_PUBKEY#"${SSH_PUBKEY%%[![:space:]]*}"}"  # trim leading whitespace
SSH_PUBKEY="${SSH_PUBKEY%"${SSH_PUBKEY##*[![:space:]]}"}"  # trim trailing whitespace
if ! [[ "${SSH_PUBKEY}" =~ ^(ssh-|ecdsa-) ]]; then
    error "SSH public key must start with 'ssh-' or 'ecdsa-'. Got: ${SSH_PUBKEY:0:20}..."
fi

EXTRA_VARS=(
  -e "ansible_connection=local"
  -e "admin_user=${ADMIN_USER}"
  -e "admin_password=${ADMIN_PASSWORD}"
  -e "adguard_password=${ADGUARD_PASSWORD}"
  -e "vault_admin_ssh_pubkey=${SSH_PUBKEY}"
  -e "ssh_port=${SSH_PORT}"
  -e "wg_port=${WG_PORT}"
  -e "wg_container_port=${WG_PORT}"
  -e "wg_vpn_subnet=10.8.0.0/24"
  -e "wg_server_ip=10.8.0.1"
  -e "wg_client_dns=172.20.0.2"
  -e "docker_network_subnet=172.20.0.0/24"
  -e "adguard_container_ip=172.20.0.2"
  -e "caddy_container_ip=172.20.0.3"
  -e "wg_easy_container_ip=172.20.0.4"
  -e "wg_internal_domain=${WG_INTERNAL_DOMAIN}"
  -e "adguard_internal_domain=${ADGUARD_INTERNAL_DOMAIN}"
  -e "wg_easy_bootstrap_ui_port=51821"
  -e "adguard_bootstrap_ui_port=3000"
  -e "project_root=/opt/zero-trust-vps"
  -e "vps_hardening_apply_package_upgrade=false"
  -e "vps_hardening_package_upgrade_mode=safe"
  -e "fail2ban_ignore_ips=['127.0.0.1/8']"
  -e "ssh_service_name=ssh"
  -e "ssh_allow_tcp_forwarding=yes"
  -e "admin_group=sudo"
)

info "Running ansible-playbook..."
if ! ansible-playbook -i inventory/localhost.yml site.yml "${EXTRA_VARS[@]}" --syntax-check 2>/dev/null; then
    warn "Syntax check failed. Review playbook before re-running."
    error "Aborting deployment."
fi
if ansible-playbook -i inventory/localhost.yml site.yml "${EXTRA_VARS[@]}"; then
    info "Playbook completed successfully."
else
    error "Playbook failed. Check output above for details."
fi

info "Creating ${MARKER_FILE} marker..."
touch "${MARKER_FILE}"

cat <<EOF

================================================================================
                         DEPLOYMENT COMPLETE
================================================================================

Access your services via SSH tunnels:

  # wg-easy (WireGuard UI) — complete setup wizard here first
  ssh -p ${SSH_PORT} -L 51821:127.0.0.1:51821 localhost

  # AdGuard Home admin UI
  ssh -p ${SSH_PORT} -L 3000:127.0.0.1:3000 localhost

  # After connecting via WireGuard, access internal domains:
  #   https://${WG_INTERNAL_DOMAIN}
  #   https://${ADGUARD_INTERNAL_DOMAIN}

================================================================================

To re-run this bootstrap: ./bootstrap.sh --force

EOF
