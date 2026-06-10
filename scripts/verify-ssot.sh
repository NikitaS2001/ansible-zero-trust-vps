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
for tool in ansible-inventory ansible-playbook ansible-pull ansible-lint yamllint; do
    command -v "${tool}" >/dev/null 2>&1 || fail "required tool not found: ${tool}"
done
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

assert_no_role_defaults_in_script() {
    local script_path="$1"

    if awk '!/^[[:space:]]*#/' "${script_path}" \
        | grep -Eq '(^|[^0-9])(2222|51820|51821|3000)([^0-9]|$)|sysadmin|10\.8\.0\.|172\.20\.0\.|project_root[[:space:]]*=|PROJECT_ROOT='; then
        fail "${script_path} must not duplicate Ansible role defaults"
    fi
}

assert_yaml_scalar_default() {
    local defaults_file="$1"
    local key="$2"
    local expected="$3"
    local actual

    actual="$(
        awk -F: -v key="${key}" '
            $1 == key {
                value = $0
                sub(/^[^:]+:[[:space:]]*/, "", value)
                gsub(/^["'\''"]|["'\''"]$/, "", value)
                print value
                exit
            }
        ' "${defaults_file}"
    )"
    [[ "${actual}" == "${expected}" ]] \
        || fail "${defaults_file} must set ${key} to ${expected}; got '${actual}'"
}

assert_role_defaults_cover_bootstrap_values() {
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_port 2222
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml wg_port 51820
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml admin_user sysadmin
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml admin_group sudo
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_service_name ssh
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml ssh_allow_tcp_forwarding yes
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml wg_easy_bootstrap_ui_port 51821
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml adguard_bootstrap_ui_port 3000
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml vps_hardening_apply_package_upgrade false
    assert_yaml_scalar_default roles/vps_hardening/defaults/main.yml vps_hardening_package_upgrade_mode safe
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml project_root /opt/zero-trust-vps
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml docker_network_subnet 172.20.0.0/24
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_container_ip 172.20.0.2
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml caddy_container_ip 172.20.0.3
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_easy_container_ip 172.20.0.4
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_vpn_subnet 10.8.0.0/24
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_server_ip 10.8.0.1
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_client_dns 172.20.0.2
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_container_port 51820
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_internal_domain wg.internal
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_internal_domain adguard.internal
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_easy_bootstrap_ui_port 51821
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_bootstrap_ui_port 3000
}

[[ -x install.sh ]] || fail "install.sh must exist and be executable"
grep -q 'v1.0.0/install.sh' README.md \
    || fail "README.md must document the tagged public install.sh quickstart"
! grep -q 'raw.githubusercontent.com/NikitaS2001/ansible-zero-trust-vps/main/bootstrap.sh' README.md \
    || fail "README.md public quickstart must not install bootstrap.sh from main"
grep -q 'ansible-pull' install.sh \
    || fail "install.sh must call ansible-pull"
grep -q 'ansible-galaxy.*collection install -r' install.sh \
    || fail "install.sh must install collections from requirements.yml"
! grep -Eiq 'community[._-]?docker|community[[:space:]]*:[[:space:]]*docker' install.sh bootstrap.sh \
    || fail "installer scripts must not install Ansible collections through pip"
assert_no_role_defaults_in_script install.sh
assert_no_role_defaults_in_script bootstrap.sh
assert_no_role_defaults_in_script scripts/installer-common.sh
assert_role_defaults_cover_bootstrap_values
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
