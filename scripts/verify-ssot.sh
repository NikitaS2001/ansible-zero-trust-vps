#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMP_BASE%/}/ssot-verify.XXXXXX")"
LOCAL_TEMP="${WORK_DIR}/ansible-local"
REMOTE_TEMP="${WORK_DIR}/ansible-remote"
REMOTE_INVENTORY="${WORK_DIR}/hosts.yml"
PULL_CHECKOUT="${WORK_DIR}/ansible-pull-checkout"

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

[[ -x install.sh ]] || fail "install.sh must exist and be executable"
grep -q 'v1.0.0/install.sh' README.md \
    || fail "README.md must document the tagged public install.sh quickstart"
! grep -q 'raw.githubusercontent.com/NikitaS2001/ansible-zero-trust-vps/main/bootstrap.sh' README.md \
    || fail "README.md public quickstart must not install bootstrap.sh from main"
grep -q 'ansible-pull' install.sh \
    || fail "install.sh must call ansible-pull"
grep -q 'ansible-galaxy.*collection install -r' install.sh \
    || fail "install.sh must install collections from requirements.yml"
! grep -q 'community.docker' install.sh \
    || fail "install.sh must not install Ansible collections through pip"
! grep -Eq '(^|[^0-9])(2222|51820|51821|3000)([^0-9]|$)|sysadmin|10\.8\.0\.|172\.20\.0\.|project_root' install.sh \
    || fail "install.sh must not duplicate Ansible role defaults"
pass "public installer follows tagged quickstart and strict SSOT rules"

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

ansible-pull -U "file://${ROOT_DIR}" \
    -d "${PULL_CHECKOUT}" \
    -i inventory/localhost.yml \
    tests/ansible-pull-smoke.yml >/dev/null
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
