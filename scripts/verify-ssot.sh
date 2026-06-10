#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
LOCAL_TEMP="${TMP_BASE%/}/ansible-local"
REMOTE_TEMP="${TMP_BASE%/}/ansible-remote"
REMOTE_INVENTORY="$(mktemp "${TMP_BASE%/}/hosts.XXXXXX.yml")"
LOCAL_INVENTORY_JSON="$(mktemp "${TMP_BASE%/}/ssot-local-inventory.XXXXXX.json")"
REMOTE_INVENTORY_JSON="$(mktemp "${TMP_BASE%/}/ssot-remote-inventory.XXXXXX.json")"

cleanup() {
    rm -f "${REMOTE_INVENTORY}" "${LOCAL_INVENTORY_JSON}" "${REMOTE_INVENTORY_JSON}"
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
mkdir -p "${LOCAL_TEMP}" "${REMOTE_TEMP}"
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

ansible-inventory -i inventory/localhost.yml --list >"${LOCAL_INVENTORY_JSON}"
grep -q '"vps"' "${LOCAL_INVENTORY_JSON}" \
    || fail "inventory/localhost.yml must define the vps group"
pass "local inventory defines vps"

cp inventory/hosts.yml.example "${REMOTE_INVENTORY}"
ansible-inventory -i "${REMOTE_INVENTORY}" --list >"${REMOTE_INVENTORY_JSON}"
grep -q '"vps"' "${REMOTE_INVENTORY_JSON}" \
    || fail "inventory/hosts.yml.example must define the vps group when parsed as YAML"
pass "remote inventory example defines vps"

ansible-playbook -i inventory/localhost.yml site.yml --syntax-check >/dev/null
ansible-playbook -i "${REMOTE_INVENTORY}" site.yml --syntax-check >/dev/null
pass "syntax-check passes for local and remote inventories"

ansible-lint site.yml roles/vps_hardening roles/vps_orchestration >/dev/null
pass "ansible-lint passes"

yamllint -c .yamllint \
    site.yml \
    inventory/localhost.yml \
    group_vars/all/vars.yml.example \
    roles/vps_hardening/defaults/main.yml \
    roles/vps_orchestration/defaults/main.yml >/dev/null
pass "yamllint passes for changed YAML surfaces"
