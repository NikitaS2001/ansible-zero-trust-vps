#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
ROLE_DIR="${ROOT_DIR}/roles/vps_hardening"
readonly ROLE_DIR
RUNTIME_LOG_DIR=""

cleanup() {
    [[ -z ${RUNTIME_LOG_DIR} || ! -d ${RUNTIME_LOG_DIR} ]] || find "${RUNTIME_LOG_DIR}" -depth -delete
}

trap cleanup EXIT

fail() {
    printf 'hardening-contract: %s\n' "$*" >&2
    exit 1
}

require_before() {
    local file="$1" first="$2" second="$3" first_line second_line
    first_line="$(rg -n -F -- "${first}" "${file}" | head -n1 | cut -d: -f1 || true)"
    second_line="$(rg -n -F -- "${second}" "${file}" | head -n1 | cut -d: -f1 || true)"
    [[ -n ${first_line} && -n ${second_line} && ${first_line} -lt ${second_line} ]] \
        || fail "expected ${first} before ${second} in ${file}"
}

validate_argument_spec() {
    HARDENING_ROLE_DIR="${ROLE_DIR}" python3 - <<'PY'
from pathlib import Path
import os
import yaml

role_dir = Path(os.environ["HARDENING_ROLE_DIR"])
document = yaml.safe_load((role_dir / "meta/main.yml").read_text(encoding="utf-8"))
if not isinstance(document, dict):
    raise SystemExit("meta/main.yml is not a mapping")
spec = document.get("argument_specs", {}).get("main", {})
options = spec.get("options", {}) if isinstance(spec, dict) else {}
expected = {
    "ssh_port", "wg_port", "admin_user", "admin_group", "admin_shell",
    "admin_password_hash", "vault_admin_ssh_pubkey",
    "vps_hardening_authorized_keys_exclusive", "ssh_service_name", "ssh_socket_name",
    "ssh_allow_tcp_forwarding", "vps_hardening_manage_ssh_socket",
    "wg_easy_bootstrap_ui_port", "adguard_bootstrap_ui_port", "fail2ban_ignore_ips",
    "fail2ban_bantime", "fail2ban_findtime", "fail2ban_maxretry",
    "vps_hardening_apply_package_upgrade", "vps_hardening_package_upgrade_mode",
    "vps_hardening_enable_ufw_on_local_connection",
}
missing = sorted(expected - set(options))
if missing:
    raise SystemExit(f"argument spec misses: {', '.join(missing)}")
if "admin_password" in options:
    raise SystemExit("argument spec must not accept deprecated admin_password")
for name in expected:
    option = options[name]
    if not isinstance(option, dict) or not option.get("type"):
        raise SystemExit(f"argument spec has no type for {name}")
PY
}

validate_fqcn() {
    HARDENING_ROLE_DIR="${ROLE_DIR}" python3 - <<'PY'
from pathlib import Path
import os
import yaml

role_dir = Path(os.environ["HARDENING_ROLE_DIR"])
bare_modules = {
    "apt", "assert", "command", "copy", "debug", "fail", "group",
    "include_tasks", "meta", "service", "set_fact", "stat", "template",
    "user", "wait_for",
}
errors = []

def inspect_tasks(tasks: object, source: Path) -> None:
    if not isinstance(tasks, list):
        return
    for task in tasks:
        if not isinstance(task, dict):
            continue
        for module in sorted(bare_modules.intersection(task)):
            errors.append(f"{source}: bare module {module}")
        for block_name in ("block", "rescue", "always"):
            inspect_tasks(task.get(block_name), source)

for directory in (role_dir / "tasks", role_dir / "handlers"):
    for source in sorted(directory.glob("*.yml")):
        inspect_tasks(yaml.safe_load(source.read_text(encoding="utf-8")), source)

if errors:
    raise SystemExit("\n".join(errors))
PY
}

validate_no_swap_management() {
    local forbidden
    forbidden="$(rg -n -i \
        '(vps_swap_mode|zram-tools|\b(swapon|swapoff|mkswap)\b|/swap(file)?\b)' "${ROLE_DIR}" || true)"
    [[ -z ${forbidden} ]] || fail "swap or zram management was introduced:\n${forbidden}"
}

validate_plaintext_password_policy() {
    ! rg -Pq '\badmin_password\b' "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user tasks still consume deprecated admin_password'
    ! rg -Pq '\bpassword_hash\s*\(' "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user tasks still derive password hashes'
    ! rg -Fq "lookup('password'" "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user tasks still generate password material'
    rg -Fq 'password: "{{ admin_password_hash | default(omit, true) }}"' "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user task does not omit an empty optional password hash'
}

validate_always_preflight() {
    rg -Fq 'tags: [always, preflight]' "${ROLE_DIR}/tasks/main.yml" \
        || fail 'preflight include is not tagged always'
    [[ "$(rg -Fc 'tags: [always, preflight]' "${ROLE_DIR}/tasks/preflight.yml")" -ge 4 ]] \
        || fail 'platform, memory, and legacy preflights are not tagged always'
}

validate_platform_policy() {
    rg -Fq "== 'Debian'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Debian platform validation'
    rg -Fq "== '12'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Debian 12 validation'
    rg -Fq "== 'Ubuntu'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Ubuntu platform validation'
    rg -Fq "== '24.04'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Ubuntu 24.04 validation'
    rg -Fq "== 'x86_64'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks amd64 architecture validation'
}

run_rejection_fixture() {
    local architecture artifact_dir case_name distribution distribution_major distribution_version fixture_dir legacy_password memory_mib run_log run_rc selected_tag swap_after swap_before
    case_name="$1"
    memory_mib="$2"
    selected_tag="$3"
    legacy_password="$4"
    distribution="$5"
    distribution_major="$6"
    distribution_version="$7"
    architecture="$8"
    fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hardening-${case_name}.XXXXXX")"
    run_log="${fixture_dir}/run.log"
    printf '%s\n' \
        '---' \
        'all:' \
        '  hosts:' \
        '    localhost:' \
        '      ansible_connection: local' >"${fixture_dir}/inventory.yml"
    {
        printf '%s\n' \
            '---' \
            '- name: Hardening preflight contract' \
            '  hosts: localhost' \
            '  gather_facts: false' \
            '  become: false'
        if [[ -n ${legacy_password} ]]; then
            printf '%s\n' '  vars:' "    admin_password: ${legacy_password}"
        fi
        printf '%s\n' \
            '  pre_tasks:' \
            '    - name: Supply platform and physical memory facts' \
            '      ansible.builtin.set_fact:' \
            "        ansible_distribution: ${distribution}" \
            "        ansible_distribution_major_version: '${distribution_major}'" \
            "        ansible_distribution_version: '${distribution_version}'" \
            "        ansible_architecture: ${architecture}" \
            "        ansible_memtotal_mb: ${memory_mib}" \
            '      tags: [always]' \
            '  roles:' \
            "    - role: ${ROLE_DIR}"
    } >"${fixture_dir}/site.yml"

    swap_before="$(< /proc/swaps)"
    set +e
    ansible-playbook --tags "${selected_tag}" -i "${fixture_dir}/inventory.yml" "${fixture_dir}/site.yml" >"${run_log}" 2>&1
    run_rc=$?
    set -e
    swap_after="$(< /proc/swaps)"
    [[ ${swap_before} == "${swap_after}" ]] || fail "${case_name} changed host swap state"
    [[ ${run_rc} -ne 0 ]] || fail "${case_name} fixture unexpectedly succeeded"
    ! grep -Fq 'VPS Hardening | Packages |' "${run_log}" \
        || fail "${case_name} fixture reached package mutation tasks"
    ! grep -Fq 'VPS Hardening | User |' "${run_log}" \
        || fail "${case_name} fixture reached user mutation tasks"
    ! grep -Fq 'Check TUN device' "${run_log}" \
        || fail "${case_name} fixture reached TUN checks"
    cp -- "${run_log}" "${RUNTIME_LOG_DIR}/${case_name}.log"
    chmod 0600 "${RUNTIME_LOG_DIR}/${case_name}.log"
    artifact_dir="${HARDENING_CONTRACT_ARTIFACT_DIR:-}"
    if [[ -n ${artifact_dir} ]]; then
        [[ -d ${artifact_dir} ]] || fail "artifact directory does not exist: ${artifact_dir}"
        cp -- "${run_log}" "${artifact_dir}/${case_name}.log"
        chmod 0600 "${artifact_dir}/${case_name}.log"
    fi
    find "${fixture_dir}" -depth -delete
}

validate_memory_preflight() {
    run_rejection_fixture memory-preflight-packages-tag 1023 packages '' Debian 12 12 x86_64
    grep -Fq 'requires at least 1024 MiB of physical RAM' \
        "${RUNTIME_LOG_DIR}/memory-preflight-packages-tag.log" \
        || fail 'packages-tag fixture omitted the expected memory diagnostic'
}

validate_plaintext_rejection() {
    run_rejection_fixture plaintext-password-preflight 1024 preflight legacy-test-password Debian 12 12 x86_64
    local artifact_path="${RUNTIME_LOG_DIR}/plaintext-password-preflight.log"
    grep -Fq 'admin_password is no longer accepted' "${artifact_path}" \
        || fail 'plaintext rejection fixture omitted the expected diagnostic'
}

validate_platform_rejection() {
    local architecture_path os_path
    run_rejection_fixture unsupported-os-packages-tag 2048 packages '' Debian 11 11 x86_64
    os_path="${RUNTIME_LOG_DIR}/unsupported-os-packages-tag.log"
    grep -Fq 'supports Debian 12 and Ubuntu 24.04 only' "${os_path}" \
        || fail 'unsupported OS fixture omitted the expected diagnostic'

    run_rejection_fixture unsupported-architecture-packages-tag 2048 packages '' Ubuntu 24 24.04 aarch64
    architecture_path="${RUNTIME_LOG_DIR}/unsupported-architecture-packages-tag.log"
    grep -Fq 'supports amd64 (x86_64) only' "${architecture_path}" \
        || fail 'unsupported architecture fixture omitted the expected diagnostic'
}

main() {
    command -v python3 >/dev/null || fail 'python3 is required'
    command -v rg >/dev/null || fail 'rg is required'
    command -v ansible-playbook >/dev/null || fail 'ansible-playbook is required'
    [[ -r /proc/swaps ]] || fail '/proc/swaps is required for swap-state observation'
    [[ -f "${ROLE_DIR}/meta/main.yml" ]] || fail 'role argument spec is missing'
    RUNTIME_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hardening-contract.XXXXXX")"

    validate_argument_spec
    validate_fqcn
    validate_no_swap_management
    validate_plaintext_password_policy
    validate_always_preflight
    validate_platform_policy
    require_before "${ROLE_DIR}/tasks/main.yml" 'Include preflight checks' 'Include package setup'
    require_before "${ROLE_DIR}/tasks/main.yml" 'Include package setup' 'Include user setup'
    require_before "${ROLE_DIR}/tasks/preflight.yml" 'Require at least 1024 MiB of physical RAM' 'Check TUN device'
    rg -Fq -- '- sudo' "${ROLE_DIR}/tasks/packages.yml" || fail 'sudo is not installed before user mutation'
    rg -Fq -- "validate: 'visudo -cf %s'" "${ROLE_DIR}/tasks/user.yml" \
        || fail 'sudoers drop-in is not validated with visudo'
    validate_memory_preflight
    validate_plaintext_rejection
    validate_platform_rejection

    printf '%s\n' '{"argument_specs":true,"fqcn":true,"platform_preflight_always":true,"packages_tag_platform_rejection":true,"ram_preflight_always":true,"packages_tag_memory_rejection":true,"plaintext_password_rejected":true,"swap_static_guard":true,"swap_unchanged_on_rejection":true,"sudo_before_user":true}'
}

main "$@"
