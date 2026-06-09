#!/usr/bin/env bash
# =============================================================================
# Zero-Trust VPS Bootstrap Script (Local Execution)
# =============================================================================
# Interactive bootstrap for local ansible-playbook execution.
# Usage: ./bootstrap.sh [--force]
# =============================================================================

set -euo pipefail

# ---- Constants ----------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INVENTORY_FILE="${REPO_ROOT}/inventory/localhost.yml"
readonly VARS_FILE="${REPO_ROOT}/group_vars/all/vars.yml"
readonly MARKER_FILE="${REPO_ROOT}/.bootstrapped"

# Default values for interactive prompts
DEFAULT_SSH_PORT="2222"
DEFAULT_WG_PORT="51820"
DEFAULT_ADMIN_USER="sysadmin"
DEFAULT_INTERNAL_DOMAINS="wg.internal adguard.internal"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--force]

Interactive bootstrap script for local ansible-playbook deployment.

This script:
  1. Validates prerequisites and checks for existing deployment
  2. Installs python3, pip, ansible, and community.docker collection
  3. Prompts for 7 configuration parameters
  4. Generates inventory/localhost.yml and group_vars/all/vars.yml
  5. Runs ansible-playbook site.yml locally
  6. Creates .bootstrapped marker on success

Options:
  --force    Overwrite existing deployment (skip .bootstrapped and inventory checks)

Arguments:
  None (interactive)

Examples:
  ./bootstrap.sh              # Normal run (aborts if already bootstrapped)
  ./bootstrap.sh --force      # Re-run even if already bootstrapped

EOF
}

# =============================================================================
# Logging helpers
# =============================================================================
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# =============================================================================
# Parse --force flag
# =============================================================================
FORCE_MODE=false
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

# =============================================================================
# Pre-flight checks
# =============================================================================
info "Running pre-flight checks..."

# Check for existing deployment (unless --force)
if [[ -f "${MARKER_FILE}" ]] || [[ -f "${INVENTORY_FILE}" ]]; then
    if [[ "${FORCE_MODE}" == "false" ]]; then
        warn "Deployment detected. Found:"
        [[ -f "${MARKER_FILE}" ]] && warn "  - ${MARKER_FILE}"
        [[ -f "${INVENTORY_FILE}" ]] && warn "  - ${INVENTORY_FILE}"
        error "Run with --force to overwrite, or remove these files first."
    fi
    warn "Overwriting existing deployment (--force mode)..."
fi

# Verify we're in the correct directory
if [[ ! -f "${REPO_ROOT}/site.yml" ]]; then
    error "site.yml not found. Are you running from the repository root?"
fi

# =============================================================================
# Install system dependencies
# =============================================================================
info "Installing system dependencies (python3, pip)..."
if ! command -v python3 &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip >/dev/null 2>&1 \
        || error "Failed to install python3/pip. Please install manually."
fi

# =============================================================================
# Install ansible and community.docker collection
# =============================================================================
info "Installing ansible and community.docker..."
pip3 install --quiet ansible "community.docker>=4.0.0,<5.0.0" 2>/dev/null \
    || error "Failed to install ansible. Check pip permissions."

# =============================================================================
# Interactive prompts
# =============================================================================
info "Starting interactive configuration..."

# --- 1. SSH port ---
read -p "SSH port [${DEFAULT_SSH_PORT}]: " SSH_PORT
SSH_PORT="${SSH_PORT:-${DEFAULT_SSH_PORT}}"
if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || \
   [[ "${SSH_PORT}" -lt 1024 ]] || [[ "${SSH_PORT}" -gt 65535 ]]; then
    error "SSH port must be a number between 1024 and 65535. Got: ${SSH_PORT}"
fi

# --- 2. WireGuard port ---
read -p "WireGuard port [${DEFAULT_WG_PORT}]: " WG_PORT
WG_PORT="${WG_PORT:-${DEFAULT_WG_PORT}}"
if ! [[ "${WG_PORT}" =~ ^[0-9]+$ ]] || \
   [[ "${WG_PORT}" -lt 1024 ]] || [[ "${WG_PORT}" -gt 65535 ]]; then
    error "WireGuard port must be a number between 1024 and 65535. Got: ${WG_PORT}"
fi

# --- 3. Admin username ---
read -p "Admin username [${DEFAULT_ADMIN_USER}]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-${DEFAULT_ADMIN_USER}}"
if ! [[ "${ADMIN_USER}" =~ ^[a-z0-9]+$ ]]; then
    error "Admin username must be lowercase alphanumeric. Got: ${ADMIN_USER}"
fi

# --- 4. Admin password ---
while true; do
    read -s -p "Admin password (min 8 chars): " ADMIN_PASSWORD
    echo
    if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
        warn "Password must be at least 8 characters."
        continue
    fi
    break
done

# --- 5. AdGuard admin password ---
while true; do
    read -s -p "AdGuard admin password (min 8 chars): " ADGUARD_PASSWORD
    echo
    if [[ ${#ADGUARD_PASSWORD} -lt 8 ]]; then
        warn "Password must be at least 8 characters."
        continue
    fi
    break
done

# --- 6. Internal domains ---
read -p "Internal domains [${DEFAULT_INTERNAL_DOMAINS}]: " INTERNAL_DOMAINS
INTERNAL_DOMAINS="${INTERNAL_DOMAINS:-${DEFAULT_INTERNAL_DOMAINS}}"
WG_INTERNAL_DOMAIN="$(echo "${INTERNAL_DOMAINS}" | awk '{print $1}')"
ADGUARD_INTERNAL_DOMAIN="$(echo "${INTERNAL_DOMAINS}" | awk '{print $2}')"
if [[ -z "${WG_INTERNAL_DOMAIN}" ]] || [[ -z "${ADGUARD_INTERNAL_DOMAIN}" ]]; then
    error "Need at least 2 domains (e.g. 'wg.internal adguard.internal'). Got: ${INTERNAL_DOMAINS}"
fi

# --- 7. SSH public key ---
read -p "SSH public key: " SSH_PUBKEY
SSH_PUBKEY="${SSH_PUBKEY#"${SSH_PUBKEY%%[![:space:]]*}"}"  # trim leading whitespace
SSH_PUBKEY="${SSH_PUBKEY%"${SSH_PUBKEY##*[![:space:]]}"}"  # trim trailing whitespace
if ! [[ "${SSH_PUBKEY}" =~ ^(ssh-|ecdsa-) ]]; then
    error "SSH public key must start with 'ssh-' or 'ecdsa-'. Got: ${SSH_PUBKEY:0:20}..."
fi

# =============================================================================
# Generate inventory/localhost.yml
# =============================================================================
info "Generating ${INVENTORY_FILE}..."
mkdir -p "${REPO_ROOT}/inventory"
cat > "${INVENTORY_FILE}" <<EOF
---
all:
  children:
    vps:
      hosts:
        localhost:
          ansible_connection: local
EOF

# =============================================================================
# Generate group_vars/all/vars.yml
# =============================================================================
info "Generating ${VARS_FILE}..."
mkdir -p "${REPO_ROOT}/group_vars/all"

# Compute derived values
WG_VPN_SUBNET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
WG_CLIENT_DNS="172.20.0.2"
DOCKER_NETWORK_SUBNET="172.20.0.0/24"
ADGUARD_CONTAINER_IP="172.20.0.2"
CADDY_CONTAINER_IP="172.20.0.3"
WG_EASY_CONTAINER_IP="172.20.0.4"
PROJECT_ROOT="/opt/zero-trust-vps"
WG_EASY_BOOTSTRAP_UI_PORT="51821"
ADGUARD_BOOTSTRAP_UI_PORT="3000"

cat > "${VARS_FILE}" <<EOF
# Network
ssh_port: ${SSH_PORT}
wg_port: ${WG_PORT}
wg_container_port: ${WG_PORT}
wg_vpn_subnet: "${WG_VPN_SUBNET}"
wg_server_ip: "${WG_SERVER_IP}"
wg_client_dns: "${WG_CLIENT_DNS}"

# Docker network
docker_network_subnet: "${DOCKER_NETWORK_SUBNET}"
adguard_container_ip: "${ADGUARD_CONTAINER_IP}"
caddy_container_ip: "${CADDY_CONTAINER_IP}"
wg_easy_container_ip: "${WG_EASY_CONTAINER_IP}"

# Internal domains
wg_internal_domain: "${WG_INTERNAL_DOMAIN}"
adguard_internal_domain: "${ADGUARD_INTERNAL_DOMAIN}"

# Bootstrap admin UI access through SSH local forwarding
wg_easy_bootstrap_ui_port: ${WG_EASY_BOOTSTRAP_UI_PORT}
adguard_bootstrap_ui_port: ${ADGUARD_BOOTSTRAP_UI_PORT}

# Remote host paths
project_root: "${PROJECT_ROOT}"

# Docker apt config
docker_apt_distribution: "{{ ansible_distribution | lower }}"
docker_apt_release: "{{ ansible_distribution_release }}"
docker_apt_arch_map:
  x86_64: amd64
  aarch64: arm64
  armv7l: armhf
docker_apt_arch: "{{ docker_apt_arch_map[ansible_architecture] | default(ansible_architecture) }}"
docker_apt_gpg_url: "https://download.docker.com/linux/{{ docker_apt_distribution }}/gpg"
docker_apt_repo_url: "https://download.docker.com/linux/{{ docker_apt_distribution }}"
docker_apt_gpg_checksum: "sha256:1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570"
ufw_docker_commit: "020a8699f95592561f254d8d4ad1bb40d401dfc7"
ufw_docker_checksum: "sha256:643e56b080567c567b4aa28650196849b2a2da5dd0473fd3e5216b0886035ab0"

# Package upgrade policy
vps_hardening_apply_package_upgrade: false
vps_hardening_package_upgrade_mode: "safe"

# Fail2Ban
fail2ban_ignore_ips:
  - "127.0.0.1/8"

# Admin user
admin_user: "${ADMIN_USER}"
ssh_service_name: "ssh"
ssh_allow_tcp_forwarding: "yes"

# Certificate fetch settings
root_ca_path_on_host: "{{ project_root }}/volumes/caddy/data/caddy/pki/authorities/local/root.crt"
fetched_certs_dir: "fetched_certs"

# Plaintext vault-compatible vars (roles consume these directly)
vault_admin_ssh_pubkey: "${SSH_PUBKEY}"
admin_password: "${ADMIN_PASSWORD}"
adguard_password: "${ADGUARD_PASSWORD}"
EOF

# =============================================================================
# Run ansible-playbook
# =============================================================================
info "Running ansible-playbook..."
cd "${REPO_ROOT}"

# Check syntax first
if ! ansible-playbook -i "${INVENTORY_FILE}" site.yml --syntax-check 2>/dev/null; then
    warn "Syntax check failed. Review generated files before re-running."
    error "Aborting deployment."
fi

# Run the playbook
if ansible-playbook -i "${INVENTORY_FILE}" site.yml; then
    info "Playbook completed successfully."
else
    error "Playbook failed. Check output above for details."
fi

# =============================================================================
# Create marker file on success
# =============================================================================
info "Creating ${MARKER_FILE} marker..."
touch "${MARKER_FILE}"

# =============================================================================
# Post-install summary
# =============================================================================
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