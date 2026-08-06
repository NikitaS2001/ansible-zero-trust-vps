#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMP_BASE%/}/ssot-verify.XXXXXX")"
LOCAL_TEMP="${WORK_DIR}/ansible-local"
REMOTE_TEMP="${WORK_DIR}/ansible-remote"
REMOTE_INVENTORY="${WORK_DIR}/hosts.yml"
PULL_SOURCE="${WORK_DIR}/ansible-pull-source"
PULL_CHECKOUT="${WORK_DIR}/ansible-pull-checkout"
PULL_LOG="${WORK_DIR}/ansible-pull-smoke.log"

cleanup() {
    if [[ -n "${WORK_DIR:-}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

cd "${ROOT_DIR}"
for tool in ansible-inventory ansible-playbook ansible-pull ansible-lint python3 yamllint; do
    command -v "${tool}" >/dev/null 2>&1 || fail "required tool not found: ${tool}"
done
python3 -c 'import yaml' >/dev/null 2>&1 || fail "required Python module not found: yaml"
pass "required tools are available"

mkdir -p "${LOCAL_TEMP}" "${REMOTE_TEMP}" "${PULL_CHECKOUT}"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-${LOCAL_TEMP}}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-${REMOTE_TEMP}}"

host_count="$(grep -Ec '^[[:space:]]+hosts:[[:space:]]+vps$' site.yml)"
[[ "${host_count}" == "2" ]] || fail "site.yml must contain exactly two 'hosts: vps' entries"
! grep -Eq '^[[:space:]]+hosts:[[:space:]]+all$' site.yml || fail "site.yml must not contain 'hosts: all'"
pass "site.yml targets the vps group consistently"

grep -q 'ghcr.io/wg-easy/wg-easy:15.3.0' README.md \
    || fail "README.md must document wg-easy 15.3.0"
grep -q 'ghcr.io/wg-easy/wg-easy:15.3.0' roles/vps_orchestration/README.md \
    || fail "roles/vps_orchestration/README.md must document wg-easy 15.3.0"
pass "README files agree on wg-easy 15.3.0"

grep -q 'image: ghcr.io/wg-easy/wg-easy:{{ wg_easy_version }}' roles/vps_orchestration/templates/docker-compose.yml.j2 \
    || fail "wg-easy image tag must be variable-driven"
grep -q 'image: adguard/adguardhome:{{ adguard_version }}' roles/vps_orchestration/templates/docker-compose.yml.j2 \
    || fail "AdGuard image tag must be variable-driven"
grep -q 'image: caddy:{{ caddy_version }}' roles/vps_orchestration/templates/docker-compose.yml.j2 \
    || fail "Caddy image tag must be variable-driven"
pass "service image tags are variable-driven"

assert_no_default_assignment() {
    local script_path="$1"
    local variable_name="$2"
    local forbidden_value="$3"
    local inspect_status=0

    awk -v variable_name="${variable_name}" -v forbidden_value="${forbidden_value}" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*readonly[[:space:]]+/, "", line)
            sub(/^[[:space:]]*local[[:space:]]+/, "", line)
            if (line ~ "^[[:space:]]*" variable_name "=") {
                value = line
                sub("^[[:space:]]*" variable_name "=", "", value)
                sub(/[[:space:]]*#.*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                gsub(/^["\047]|["\047]$/, "", value)
                if (value == forbidden_value) {
                    exit 42
                }
            }
        }
    ' "${script_path}" || inspect_status=$?

    if [[ "${inspect_status}" -eq 0 ]]; then
        return
    fi

    if [[ "${inspect_status}" -eq 42 ]]; then
        fail "${script_path} must not assign ${variable_name}=${forbidden_value}; use role defaults instead"
    fi

    fail "failed to inspect ${script_path} for duplicated role defaults"
}

assert_no_role_defaults_in_script() {
    local script_path="$1"

    assert_no_default_assignment "${script_path}" SSH_PORT 2222
    assert_no_default_assignment "${script_path}" WG_PORT 51820
    assert_no_default_assignment "${script_path}" ADMIN_USER sysadmin
    assert_no_default_assignment "${script_path}" ADMIN_GROUP sudo
    assert_no_default_assignment "${script_path}" SSH_SERVICE_NAME ssh
    assert_no_default_assignment "${script_path}" WG_EASY_BOOTSTRAP_UI_PORT 51821
    assert_no_default_assignment "${script_path}" ADGUARD_BOOTSTRAP_UI_PORT 3000
    assert_no_default_assignment "${script_path}" PROJECT_ROOT /opt/zero-trust-vps
}

assert_yaml_scalar_default() {
    local defaults_file="$1"
    local key="$2"
    local expected="$3"
    local actual

    actual="$(
        python3 -c '
import sys
import yaml

defaults_file, key = sys.argv[1], sys.argv[2]
with open(defaults_file, "r", encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}

if key not in data:
    sys.exit(2)

value = data[key]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
' "${defaults_file}" "${key}"
    )" || fail "${defaults_file} must define ${key}"

    [[ "${actual}" == "${expected}" ]] \
        || fail "${defaults_file} must set ${key} to ${expected}; got '${actual}'"
}

read_install_release_ref() {
    local release_ref

    release_ref="$(
        sed -nE 's/^readonly RELEASE_REF="\$\{ZERO_TRUST_RELEASE_REF:-([^}]+)\}"$/\1/p' install.sh
    )"
    [[ -n "${release_ref}" ]] || fail "install.sh must define a default ZERO_TRUST_RELEASE_REF"
    printf '%s\n' "${release_ref}"
}

assert_role_defaults_cover_installer_values() {
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_port 2222
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml wg_port 51820
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml admin_user sysadmin
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml admin_group sudo
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml admin_shell /bin/bash
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_service_name ssh
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_socket_name ssh.socket
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_allow_tcp_forwarding yes
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml vps_hardening_manage_ssh_socket true
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml wg_easy_bootstrap_ui_port 51821
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml adguard_bootstrap_ui_port 3000
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml vps_hardening_apply_package_upgrade false
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml vps_hardening_package_upgrade_mode safe
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml vps_hardening_enable_ufw_on_local_connection false
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml project_root /opt/zero-trust-vps
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml docker_network_subnet 10.66.0.0/24
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_container_ip 10.66.0.2
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml caddy_container_ip 10.66.0.3
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_easy_container_ip 10.66.0.4
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_vpn_subnet 10.8.0.0/24
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_server_ip 10.8.0.1
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_client_dns 10.66.0.2
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_port 51820
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_container_port 51820
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_internal_domain wg.internal
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_internal_domain adguard.internal
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_easy_bootstrap_ui_port 51821
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_bootstrap_ui_port 3000
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml vps_orchestration_enable_ufw_before_ufw_docker false
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_easy_admin_user admin
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_easy_admin_password ""
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_public_host ""
}

assert_optional_installer_prompts_have_role_defaults() {
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_port 2222
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml wg_port 51820
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_port 51820
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml admin_user sysadmin
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_internal_domain wg.internal
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_internal_domain adguard.internal
}

assert_wg_allowed_ips_default() {
    python3 -c '
import sys
import yaml

with open("roles/vps_orchestration/defaults/main.yml", encoding="utf-8") as handle:
    defaults = yaml.safe_load(handle) or {}

expected = ["10.8.0.0/24", "10.66.0.2/32", "10.66.0.3/32"]
if defaults.get("wg_allowed_ips") != expected:
    sys.exit(1)
' || fail "roles/vps_orchestration/defaults/main.yml must set wg_allowed_ips to the documented internal IPs"
}

assert_installer_provides_wg_easy_init() {
    grep -q 'write_extra_var wg_easy_admin_password' install.sh         || fail "install.sh must pass wg_easy_admin_password through extra-vars"
    grep -q 'write_extra_var wg_public_host' install.sh         || fail "install.sh must pass wg_public_host through extra-vars"
    grep -q 'ZERO_TRUST_NONINTERACTIVE' install.sh         || fail "install.sh must support non-interactive mode for automated testing"
}

[[ -x install.sh ]] || fail "install.sh must exist and be executable"
install_release_ref="$(read_install_release_ref)"
grep -Fq "/${install_release_ref}/install.sh" README.md \
    || fail "README.md must document the tagged public install.sh quickstart"
grep -q 'ansible-pull' install.sh \
    || fail "install.sh must call ansible-pull"
grep -q 'ansible-galaxy.*collection install -r' install.sh \
    || fail "install.sh must install collections from requirements.yml"
! grep -Eiq 'community[._-]?docker|community[[:space:]]*:[[:space:]]*docker' install.sh \
    || fail "install.sh must not install Ansible collections through pip"
assert_no_role_defaults_in_script install.sh
assert_role_defaults_cover_installer_values
assert_optional_installer_prompts_have_role_defaults
assert_wg_allowed_ips_default
assert_installer_provides_wg_easy_init
pass "installer entrypoints follow tagged quickstart and strict SSOT rules"

ansible-inventory -i inventory/localhost.yml --graph vps >/dev/null \
    || fail "inventory/localhost.yml must define the vps group"
pass "local inventory defines vps"

cp inventory/hosts.yml.example "${REMOTE_INVENTORY}"
ansible-inventory -i "${REMOTE_INVENTORY}" --graph vps >/dev/null \
    || fail "inventory/hosts.yml.example must define the vps group when parsed as YAML"
pass "remote inventory example defines vps"

ansible-playbook -i inventory/localhost.yml site.yml --syntax-check >/dev/null
ansible-playbook -i "${REMOTE_INVENTORY}" site.yml --syntax-check >/dev/null
pass "syntax-check passes for local and remote inventories"

git clone --quiet "${ROOT_DIR}" "${PULL_SOURCE}"
git -C "${PULL_SOURCE}" checkout --quiet -B ssot-smoke HEAD

if ! env GIT_ALLOW_PROTOCOL=file ansible-pull -U "file://${PULL_SOURCE}" \
    -C ssot-smoke \
    -d "${PULL_CHECKOUT}" \
    -i inventory/localhost.yml \
    tests/ansible-pull-smoke.yml >"${PULL_LOG}" 2>&1; then
    cat "${PULL_LOG}" >&2
    fail "ansible-pull must resolve the repo inventory"
fi
pass "ansible-pull resolves the repo inventory"

ansible-lint site.yml roles/vps_hardening roles/vps_orchestration >/dev/null
pass "ansible-lint passes"

yamllint -c .yamllint \
    site.yml \
    inventory/localhost.yml \
    group_vars/all/vars.yml.example \
    roles/vps_hardening/defaults/main.yml \
    roles/vps_orchestration/defaults/main.yml >/dev/null
pass "yamllint passes for changed YAML surfaces"
