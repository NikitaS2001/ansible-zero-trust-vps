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

read_yaml_value() {
    local defaults_file="$1"
    local key="$2"

    python3 -c '
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    defaults = yaml.safe_load(handle) or {}
value = defaults.get(sys.argv[2])
if value is None:
    raise SystemExit(1)
print(value)
' "${defaults_file}" "${key}"
}

verify_doc_contract() {
    local docs_root="$1"
    local defaults_file="${ROOT_DIR}/roles/vps_orchestration/defaults/main.yml"
    local wg_version caddy_version readme_flat e2e_flat

    wg_version="$(read_yaml_value "${defaults_file}" wg_easy_version)" \
        || fail "cannot read wg_easy_version from role defaults"
    caddy_version="$(read_yaml_value "${defaults_file}" caddy_version)" \
        || fail "cannot read caddy_version from role defaults"
    readme_flat="$(tr '\n' ' ' <"${docs_root}/README.md" | tr -s '[:space:]' ' ')"
    e2e_flat="$(tr '\n' ' ' <"${docs_root}/tests/e2e/README.md" | tr -s '[:space:]' ' ')"

    grep -Fq "ghcr.io/wg-easy/wg-easy:${wg_version}" "${docs_root}/README.md" \
        || fail "README.md must document the wg-easy version from role defaults"
    grep -Fq "ghcr.io/wg-easy/wg-easy:${wg_version}" \
        "${docs_root}/roles/vps_orchestration/README.md" \
        || fail "orchestration README must document the wg-easy version from role defaults"
    grep -Fq "caddy:${caddy_version}" "${docs_root}/README.md" \
        || fail "README.md must document the Caddy version from role defaults"
    grep -Fq "caddy:${caddy_version}" "${docs_root}/roles/vps_orchestration/README.md" \
        || fail "orchestration README must document the Caddy version from role defaults"

    grep -Fq 'sudo env AGE_KEY="..." scripts/backup.sh' "${docs_root}/README.md" \
        || fail "README.md must preserve AGE_KEY explicitly through sudo env"
    grep -Fq -- '--allow-plaintext' "${docs_root}/README.md" \
        || fail "README.md must document the explicit plaintext backup escape hatch"
    grep -Eiq 'before (it )?stops? (the )?containers.*AGE_KEY.*public (age )?recipient.*age' \
        <<<"${readme_flat}" \
        || fail "README.md must state encrypted-backup prerequisites are checked before container stop"
    grep -Eiq '\.age.*0600|0600.*\.age' "${docs_root}/README.md" \
        || fail "README.md must document encrypted .age output mode 0600"

    grep -Fq "wg-easy \`${wg_version}\` remains affected by CVE-2026-63089" \
        <<<"${readme_flat}" \
        || fail "README.md must state stable wg-easy 15.3.0 remains affected"
    grep -Fq 'is not claimed as patched' "${docs_root}/README.md" \
        || fail "README.md must not claim the stable wg-easy release is patched"
    for route in '/cnf`' '/cnf/`' '/cnf/*`'; do
        grep -Fq "${route}" "${docs_root}/README.md" \
            || fail "README.md must document the complete CVE route boundary"
    done
    grep -Fq 'X-Zero-Trust-Policy: cve-2026-63089' "${docs_root}/README.md" \
        || fail "README.md must document the CVE policy response header"
    grep -Eiq '404.*normal (UI|user interface).*(API|APIs).*work|404.*normal (API|APIs).*(UI|user interface).*work' \
        <<<"${readme_flat}" \
        || fail "README.md must distinguish blocked CVE routes from working UI and API routes"
    ! grep -Fq 'Known CVE (accepted risk' "${docs_root}/README.md" \
        || fail "README.md must not describe the CVE as merely accepted risk"

    grep -Eiq 'restore validates.*stages.*activates' <<<"${readme_flat}" \
        || fail "README.md must document validate-stage-activate restore"
    grep -Eiq 'activation or startup fails.*rolls back.*prior project' <<<"${readme_flat}" \
        || fail "README.md must document restore rollback"
    grep -Eiq 'recomputes.*Compose.*readiness' <<<"${readme_flat}" \
        || fail "README.md must document restored Compose and readiness checks"

    grep -Eiq 'private candidate.*validat.*atomic.*install.*reload.*rolls? back' \
        <<<"${readme_flat}" \
        || fail "README.md must document deterministic Caddy candidate activation and rollback"
    ! grep -Eq 'docker[[:space:]]+restart[[:space:]]+caddy' "${docs_root}/README.md" \
        || fail "README.md must not direct users to bypass Caddy candidate validation"
    grep -Eiq 'private candidate.*validat.*atomic.*install.*reload.*rolls? back' \
        < <(tr '\n' ' ' <"${docs_root}/roles/vps_orchestration/README.md") \
        || fail "orchestration README must document Caddy candidate activation and rollback"

    grep -Fq 'internal_domain_suffix: home.arpa' "${docs_root}/README.md" \
        || fail "README.md must show suffix-only home.arpa configuration"
    grep -Fq 'wg.home.arpa' "${docs_root}/README.md" \
        || fail "README.md must show the resolved wg.home.arpa name"
    grep -Fq 'adguard.home.arpa' "${docs_root}/README.md" \
        || fail "README.md must show the resolved adguard.home.arpa name"
    ! grep -Fq 'e2e-public-install.yml' "${docs_root}/README.md" \
        || fail "README.md must not reference the retired external-VPS workflow"
    ! grep -ERq '(wg|adguard)\.\{\{|\*\.\{\{' \
        "${docs_root}/README.md" "${docs_root}/roles/vps_hardening/README.md" \
        "${docs_root}/roles/vps_orchestration/README.md" "${docs_root}/tests/e2e/README.md" \
        || fail "documentation examples must not expose unresolved Jinja domains"

    ! grep -Fqi 'Release readiness requires, in order, public QEMU coverage, remote QEMU coverage, the named negative cases, a fresh disposable real VPS installation' \
        <<<"${e2e_flat}" \
        || fail "documentation must not make a real VPS or external client a merge-readiness requirement"
    ! grep -Fqi 'Missing live secrets or access blocks release readiness' \
        <<<"${e2e_flat}" \
        || fail "documentation must not make live secrets or access a merge-readiness requirement"
    grep -Fqi 'Merge readiness requires disposable local public-QEMU coverage, disposable remote-QEMU coverage, the named negative cases, and the encrypted backup/restore drill.' \
        <<<"${e2e_flat}" \
        || fail "E2E README must require the disposable local and remote QEMU matrix"
    grep -Fqi 'GitHub Actions stores no VPS credential, and live external host availability is out of scope for merge readiness.' \
        <<<"${e2e_flat}" \
        || fail "E2E README must keep GitHub VPS-credential-free and external host availability out of scope"
    grep -Fqi 'QEMU does not prove provider-firewall behavior' <<<"${e2e_flat}" \
        || fail "E2E README must not claim QEMU proves provider-firewall behavior"
    grep -Fqi "provider firewall remains the operator's responsibility" \
        "${docs_root}/tests/e2e/README.md" \
        || fail "E2E README must assign provider-firewall responsibility to the operator"
}

copy_doc_fixture() {
    local destination="$1"

    mkdir -p "${destination}/roles/vps_hardening" \
        "${destination}/roles/vps_orchestration" "${destination}/tests/e2e"
    cp README.md "${destination}/README.md"
    cp roles/vps_hardening/README.md "${destination}/roles/vps_hardening/README.md"
    cp roles/vps_orchestration/README.md "${destination}/roles/vps_orchestration/README.md"
    cp tests/e2e/README.md "${destination}/tests/e2e/README.md"
}

run_doc_contract_self_test() {
    local fixture_root="${WORK_DIR}/doc-contract"
    local mutation_root old_caddy_version synthetic_help synthetic_unknown

    synthetic_help="$("${ROOT_DIR}/scripts/synthetic-check.sh" --help)" \
        || fail "synthetic-check --help must exit zero"
    grep -Fq 'Usage: synthetic-check.sh' <<<"${synthetic_help}" \
        || fail "synthetic-check --help must print usage"
    ! grep -Fq '== containers ==' <<<"${synthetic_help}" \
        || fail "synthetic-check --help must not execute live checks"
    pass "synthetic-check help is side-effect free"

    if synthetic_unknown="$("${ROOT_DIR}/scripts/synthetic-check.sh" --unknown 2>&1)"; then
        fail "synthetic-check accepted an unknown argument"
    fi
    grep -Fq 'Usage: synthetic-check.sh' <<<"${synthetic_unknown}" \
        || fail "synthetic-check unknown argument must print usage"
    ! grep -Fq '== containers ==' <<<"${synthetic_unknown}" \
        || fail "synthetic-check unknown argument must not execute live checks"
    pass "synthetic-check rejects unknown arguments before live checks"

    copy_doc_fixture "${fixture_root}"

    verify_doc_contract "${fixture_root}"
    pass "doc-contract positive fixture"

    mutation_root="${WORK_DIR}/mutation-version"
    copy_doc_fixture "${mutation_root}"
    old_caddy_version="$(read_yaml_value roles/vps_orchestration/defaults/main.yml caddy_version)"
    sed -i "s/caddy:${old_caddy_version}/caddy:2.11.3/g" \
        "${mutation_root}/roles/vps_orchestration/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a stale Caddy version"
    fi
    pass "doc-contract rejects stale service versions inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-wg-version"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/wg-easy:15\.3\.0/wg-easy:15.2.0/g' \
        "${mutation_root}/README.md" \
        "${mutation_root}/roles/vps_orchestration/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a stale wg-easy version"
    fi
    pass "doc-contract rejects stale wg-easy version inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-backup-sudo"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/sudo env AGE_KEY="\.\.\." scripts\/backup\.sh/AGE_KEY="..." sudo scripts\/backup.sh/' \
        "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted stale backup sudo syntax"
    fi
    pass "doc-contract rejects stale backup syntax inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-backup-prerequisites"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/before it stops the containers/after it stops the containers/' \
        "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted late encrypted-backup prerequisites"
    fi
    pass "doc-contract rejects missing encrypted-backup prerequisites inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-backup-plaintext"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/--allow-plaintext/--plaintext/g' "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a missing plaintext escape hatch"
    fi
    pass "doc-contract rejects missing plaintext escape hatch inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-backup-mode"
    copy_doc_fixture "${mutation_root}"
    # shellcheck disable=SC2016 # Markdown backticks are literal fixture data.
    sed -i 's/mode `0600`/mode `0644`/' "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted an unsafe backup mode"
    fi
    pass "doc-contract rejects unsafe encrypted-backup mode inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-cve-route"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/X-Zero-Trust-Policy: cve-2026-63089/X-Zero-Trust-Policy: removed/' \
        "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a missing CVE route boundary"
    fi
    pass "doc-contract rejects missing CVE route boundary inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-cve-claim"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/is not claimed as patched/is patched upstream/' "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a patched-upstream claim"
    fi
    pass "doc-contract rejects patched-upstream CVE wording inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-restore"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/it rolls back to the prior project/it replaces the prior project/' \
        "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted unsafe restore wording"
    fi
    pass "doc-contract rejects unsafe restore and restart wording inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-caddy-activation"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/private candidate/public candidate/' "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted unsafe Caddy activation wording"
    fi
    pass "doc-contract rejects unsafe Caddy activation wording inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-caddy-restart"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/do not restart Caddy directly/sudo docker restart caddy/' \
        "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted direct Caddy restart wording"
    fi
    pass "doc-contract rejects direct Caddy restart wording inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-jinja-domain"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/wg\.home\.arpa/wg.{{ internal_domain_suffix }}/' \
        "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a literal Jinja domain"
    fi
    pass "doc-contract rejects literal Jinja domains inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-live-matrix"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/disposable local public-QEMU coverage/optional local coverage/' \
        "${mutation_root}/tests/e2e/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a missing required QEMU matrix"
    fi
    pass "doc-contract rejects missing required QEMU matrix inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-provider-firewall"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/QEMU does not/QEMU does/' \
        "${mutation_root}/tests/e2e/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted QEMU provider-firewall proof wording"
    fi
    pass "doc-contract rejects QEMU provider-firewall proof wording inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-live-secrets"
    copy_doc_fixture "${mutation_root}"
    sed -i 's/GitHub Actions stores no VPS credential/GitHub Actions may store VPS credentials/' \
        "${mutation_root}/tests/e2e/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted GitHub VPS credentials"
    fi
    pass "doc-contract rejects GitHub VPS credentials inner_rc=1"

    mutation_root="${WORK_DIR}/mutation-retired-workflow-link"
    copy_doc_fixture "${mutation_root}"
    sed -i '/^2\. Update the README quickstart URL/a 2a. Update e2e-public-install.yml install_ref to the same tag.' \
        "${mutation_root}/README.md"
    if (verify_doc_contract "${mutation_root}") >/dev/null 2>&1; then
        fail "doc-contract accepted a retired workflow link"
    fi
    pass "doc-contract rejects retired workflow links inner_rc=1"
}

if [[ ${1:-} == --self-test-doc-contract ]]; then
    [[ $# -eq 1 ]] || fail "--self-test-doc-contract accepts no other arguments"
    run_doc_contract_self_test
    exit 0
fi
[[ $# -eq 0 ]] || fail "unknown argument: $1"

cd "${ROOT_DIR}"
for tool in ansible-inventory ansible-playbook ansible-pull ansible-lint python3 yamllint; do
    command -v "${tool}" >/dev/null 2>&1 || fail "required tool not found: ${tool}"
done
python3 -c 'import yaml' >/dev/null 2>&1 || fail "required Python module not found: yaml"
pass "required tools are available"
verify_doc_contract "${ROOT_DIR}"
pass "operational documentation matches enforced defaults and runtime contracts"
! rg -ni 'secrets\.[^}]*vps|E2E_VPS_' .github/workflows >/dev/null \
    || fail "GitHub Actions must store no VPS credential"
pass "GitHub Actions stores no VPS credential"

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
    [[ "${release_ref}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "install.sh default ZERO_TRUST_RELEASE_REF must be a vX.Y.Z tag; got '${release_ref}'"
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
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml internal_domain_suffix internal
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_internal_domain "wg.{{ internal_domain_suffix }}"
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_internal_domain "adguard.{{ internal_domain_suffix }}"
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
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml internal_domain_suffix internal
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml wg_internal_domain "wg.{{ internal_domain_suffix }}"
    assert_yaml_scalar_default roles/vps_orchestration/defaults/main.yml adguard_internal_domain "adguard.{{ internal_domain_suffix }}"
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

assert_extension_pattern_intact() {
    # The user-facing extension story ("add your own service behind an
    # internal domain") depends on the AdGuard wildcard rewrite and on Caddy
    # serving *.internal with the internal CA. Guard both so a future change
    # cannot silently break service additions.
    grep -Fq 'domain: "*.{{ internal_domain_suffix }}"' \
        roles/vps_orchestration/templates/AdGuardHome.yaml.j2 \
        || fail "AdGuardHome.yaml.j2 must keep the *.{{ internal_domain_suffix }} wildcard rewrite"
    grep -Fq 'tls internal' roles/vps_orchestration/templates/Caddyfile.j2 \
        || fail "Caddyfile.j2 must keep the tls internal sites"
    grep -Fq 'import Caddyfile.d/*.conf' roles/vps_orchestration/templates/Caddyfile.j2 \
        || fail "Caddyfile.j2 must import user site blocks from Caddyfile.d"
}

[[ -x install.sh ]] || fail "install.sh must exist and be executable"
# shellcheck disable=SC2016  # match the literal install.sh entry guard
grep -Fq 'BASH_SOURCE[0]:-$0' install.sh \
    || fail "install.sh must invoke main when piped to bash (unset BASH_SOURCE)"
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
assert_extension_pattern_intact
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
