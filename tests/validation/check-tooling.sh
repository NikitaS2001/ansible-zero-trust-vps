#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
readonly ROOT_DIR
readonly -a REQUIRED_VALIDATION_MANIFEST=(
    'ansible-runtime.sh|'
    'backup-sandbox.sh|'
    'installer-contract.sh|'
    'secret-installer-contract.sh|'
    'restore-sandbox.sh|'
    'compose-render.sh|'
    'traffic-mode-contract.sh|'
    'hardening-contract.sh|'
    'orchestration-core.sh|'
    'ufw-docker-idempotency.sh|'
    'workflow-contract.sh|--self-test'
    'check-tooling.sh|'
    'qemu-source-contract.sh|'
    'qemu-packet-contract.sh|'
    'sbom-contract.sh|'
)

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-tooling.XXXXXX")"
readonly TMP_DIR
trap 'find "${TMP_DIR}" -depth -delete' EXIT

mkdir -p \
    "${TMP_DIR}/bin" \
    "${TMP_DIR}/scripts" \
    "${TMP_DIR}/tests/validation" \
    "${TMP_DIR}/tests/e2e" \
    "${TMP_DIR}/inventory" \
    "${TMP_DIR}/group_vars/all"
cp "$(dirname -- "$0")/../../scripts/check.sh" "${TMP_DIR}/scripts/check.sh"
cp "$(dirname -- "$0")/../../scripts/bootstrap.sh" "${TMP_DIR}/scripts/bootstrap.sh"
chmod 0700 "${TMP_DIR}/scripts/check.sh" "${TMP_DIR}/scripts/bootstrap.sh"
touch "${TMP_DIR}/install.sh" "${TMP_DIR}/scripts/pass.sh" \
    "${TMP_DIR}/tests/e2e/pass.sh"

"${TMP_DIR}/scripts/check.sh" --help \
    >"${TMP_DIR}/check-help.stdout" 2>"${TMP_DIR}/check-help.stderr"
grep -Fq -- '--release' "${TMP_DIR}/check-help.stdout"
[[ ! -s ${TMP_DIR}/check-help.stderr ]] || {
    printf 'check-tooling: check help wrote to stderr\n' >&2
    exit 1
}
"${TMP_DIR}/scripts/bootstrap.sh" --help \
    >"${TMP_DIR}/bootstrap-help.stdout" 2>"${TMP_DIR}/bootstrap-help.stderr"
grep -Fq -- 'pinned development dependencies' "${TMP_DIR}/bootstrap-help.stdout"
[[ ! -e ${TMP_DIR}/.venv && ! -s ${TMP_DIR}/bootstrap-help.stderr ]] || {
    printf 'check-tooling: bootstrap help caused a side effect or wrote to stderr\n' >&2
    exit 1
}
if "${TMP_DIR}/scripts/check.sh" --unknown \
    >"${TMP_DIR}/unknown.stdout" 2>"${TMP_DIR}/unknown.stderr"; then
    printf 'check-tooling: unknown check option succeeded\n' >&2
    exit 1
fi
[[ ! -s ${TMP_DIR}/unknown.stdout ]] && grep -Fq 'Usage:' "${TMP_DIR}/unknown.stderr"

printf 'check-tooling: command help PASS\n'

regression_failures=0
for entry in "${REQUIRED_VALIDATION_MANIFEST[@]}"; do
    count="$(awk -v entry="${entry}" '$0 == entry { count++ } END { print count + 0 }' \
        "${ROOT_DIR}/tests/validation/manifest.txt")"
    if [[ ${count} -ne 1 ]]; then
        printf 'check-tooling: required validation manifest entry must appear exactly once: %s (found %s)\n' \
            "${entry}" "${count}" >&2
        regression_failures=1
    fi
done

for example in \
    inventory/hosts.yml \
    group_vars/all/vars.yml \
    group_vars/all/vault_services.yml \
    group_vars/all/vault_ssh.yml; do
    touch "${TMP_DIR}/${example}.example"
done

for tool in ansible-playbook ansible-lint yamllint shellcheck python3 pre-commit; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/bin/${tool}"
    chmod 0700 "${TMP_DIR}/bin/${tool}"
done
printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/scripts/verify-ssot.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/validation/workflow-contract.sh"
printf '#!/usr/bin/env bash\nexit 23\n' >"${TMP_DIR}/tests/validation/failing-contract.sh"
for entry in "${REQUIRED_VALIDATION_MANIFEST[@]}"; do
    script=${entry%%|*}
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/validation/${script}"
    chmod 0700 "${TMP_DIR}/tests/validation/${script}"
done
chmod 0700 \
    "${TMP_DIR}/scripts/verify-ssot.sh" \
    "${TMP_DIR}/tests/validation/workflow-contract.sh" \
    "${TMP_DIR}/tests/validation/failing-contract.sh"
printf '%s\n' "${REQUIRED_VALIDATION_MANIFEST[@]}" \
    >"${TMP_DIR}/tests/validation/manifest.txt"
printf 'failing-contract.sh|\n' >>"${TMP_DIR}/tests/validation/manifest.txt"

if PATH="${TMP_DIR}/bin:/usr/bin:/bin" "${TMP_DIR}/scripts/check.sh" \
    >"${TMP_DIR}/check.stdout" 2>"${TMP_DIR}/check.stderr"; then
    printf 'check-tooling: scripts/check.sh masked a failing validation contract\n' >&2
    exit 1
fi
for generated in \
    inventory/hosts.yml \
    group_vars/all/vars.yml \
    group_vars/all/vault_services.yml \
    group_vars/all/vault_ssh.yml; do
    [[ ! -e ${TMP_DIR}/${generated} ]] || {
        printf 'check-tooling: temporary example remained after failure: %s\n' "${generated}" >&2
        exit 1
    }
done

printf 'check-tooling: failure propagation PASS\n'

printf '%s\n' "${REQUIRED_VALIDATION_MANIFEST[@]}" \
    >"${TMP_DIR}/tests/validation/manifest.complete"
manifest_rejection_failed=0
representative_entry='ansible-runtime.sh|'
for mutation in missing duplicate renamed whitespace blank prefix inert; do
    cp -- "${TMP_DIR}/tests/validation/manifest.complete" \
        "${TMP_DIR}/tests/validation/manifest.txt"
    case ${mutation} in
        missing)
            grep -Fvx -- "${representative_entry}" \
                "${TMP_DIR}/tests/validation/manifest.complete" \
                >"${TMP_DIR}/tests/validation/manifest.txt"
            ;;
        duplicate) printf '%s\n' "${representative_entry}" >>"${TMP_DIR}/tests/validation/manifest.txt" ;;
        renamed)
            sed 's/^ansible-runtime\.sh|/renamed-ansible-runtime.sh|/' \
                "${TMP_DIR}/tests/validation/manifest.complete" \
                >"${TMP_DIR}/tests/validation/manifest.txt"
            printf '#!/usr/bin/env bash\nexit 0\n' \
                >"${TMP_DIR}/tests/validation/renamed-ansible-runtime.sh"
            chmod 0700 "${TMP_DIR}/tests/validation/renamed-ansible-runtime.sh"
            ;;
        whitespace)
            sed 's/^ansible-runtime\.sh|/ ansible-runtime.sh|/' \
                "${TMP_DIR}/tests/validation/manifest.complete" \
                >"${TMP_DIR}/tests/validation/manifest.txt"
            printf '#!/usr/bin/env bash\nexit 0\n' \
                >"${TMP_DIR}/tests/validation/ ansible-runtime.sh"
            chmod 0700 "${TMP_DIR}/tests/validation/ ansible-runtime.sh"
            ;;
        blank) printf '\n' >>"${TMP_DIR}/tests/validation/manifest.txt" ;;
        prefix)
            printf 'untrusted-prefix.sh|\n' >>"${TMP_DIR}/tests/validation/manifest.txt"
            printf '#!/usr/bin/env bash\nexit 0\n' \
                >"${TMP_DIR}/tests/validation/untrusted-prefix.sh"
            chmod 0700 "${TMP_DIR}/tests/validation/untrusted-prefix.sh"
            ;;
        inert) printf '%s\n' "\$(touch \"\$CHECK_TOOLING_INJECTION_MARKER\")|" >>"${TMP_DIR}/tests/validation/manifest.txt" ;;
    esac
    if CHECK_TOOLING_INJECTION_MARKER="${TMP_DIR}/injection-marker" \
        PATH="${TMP_DIR}/bin:/usr/bin:/bin" "${TMP_DIR}/scripts/check.sh" \
        >"${TMP_DIR}/${mutation}.stdout" 2>"${TMP_DIR}/${mutation}.stderr"; then
        printf 'check-tooling: %s manifest mutation succeeded: %s\n' \
            "${mutation}" "${representative_entry}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    elif [[ ${mutation} != blank && ${mutation} != prefix && ${mutation} != inert ]] && \
        ! grep -Fq -- "${representative_entry}" "${TMP_DIR}/${mutation}.stderr"; then
        printf 'check-tooling: %s manifest mutation failure did not name: %s\n' \
            "${mutation}" "${representative_entry}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    else
        printf 'check-tooling: %s rejected and named: %s\n' \
            "${mutation}" "${representative_entry}"
    fi
    [[ ! -e ${TMP_DIR}/injection-marker ]] || {
        printf 'check-tooling: manifest data was evaluated: %s\n' "${mutation}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    }
done

[[ ${manifest_rejection_failed} -ne 0 ]] \
    || printf 'check-tooling: manifest completeness rejection PASS\n'

while IFS='|' read -r script _arguments; do
    # shellcheck disable=SC2016
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$(basename "$0")" >>"$CHECK_TOOLING_LOG"' \
        >"${TMP_DIR}/tests/validation/${script}"
done <"${ROOT_DIR}/tests/validation/manifest.txt"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$(basename "$0")" >>"$CHECK_TOOLING_LOG"' \
    'cat >/dev/null' >"${TMP_DIR}/tests/validation/traffic-mode-contract.sh"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ ${1:-} != --self-test ]] || printf "%s\n" "$(basename "$0")" >>"$CHECK_TOOLING_LOG"' \
    >"${TMP_DIR}/tests/validation/workflow-contract.sh"
chmod 0700 "${TMP_DIR}/tests/validation/"*.sh
cp -- "${ROOT_DIR}/tests/validation/manifest.txt" \
    "${TMP_DIR}/tests/validation/manifest.txt"
: >"${TMP_DIR}/manifest-dispatch.log"
CHECK_TOOLING_LOG="${TMP_DIR}/manifest-dispatch.log" \
PATH="${TMP_DIR}/bin:/usr/bin:/bin" "${TMP_DIR}/scripts/check.sh" \
    >"${TMP_DIR}/manifest-dispatch.stdout" 2>"${TMP_DIR}/manifest-dispatch.stderr"
awk -F'|' '{ print $1 }' "${ROOT_DIR}/tests/validation/manifest.txt" \
    >"${TMP_DIR}/manifest-dispatch.expected"
if ! cmp "${TMP_DIR}/manifest-dispatch.expected" "${TMP_DIR}/manifest-dispatch.log"; then
    printf 'check-tooling: manifest child stdin consumed later dispatch entries\n' >&2
    regression_failures=1
else
    while IFS= read -r script; do
        printf 'check-tooling: manifest dispatch count=1: %s\n' "${script}"
    done <"${TMP_DIR}/manifest-dispatch.log"
    printf 'check-tooling: manifest stdin isolation PASS\n'
fi

for entry in "${REQUIRED_VALIDATION_MANIFEST[@]}"; do
    script=${entry%%|*}
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/validation/${script}"
done

for tool in qemu-system-x86_64 qemu-img genisoimage; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/bin/${tool}"
    chmod 0700 "${TMP_DIR}/bin/${tool}"
done
printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/validation/passing-contract.sh"
chmod 0700 "${TMP_DIR}/tests/validation/passing-contract.sh"
printf '%s\n' "${REQUIRED_VALIDATION_MANIFEST[@]}" \
    >"${TMP_DIR}/tests/validation/manifest.txt"

for script in qemu-install.sh lifecycle-qemu.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/e2e/${script}"
    chmod 0700 "${TMP_DIR}/tests/e2e/${script}"
done
for contract in \
    release-artifacts-contract.sh \
    release-workflow-contract.sh \
    release-publish-contract.sh \
    sbom-contract.sh \
    release-contract.sh; do
    # Fixture expands these variables when invoked.
    # shellcheck disable=SC2016
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "test:%s\n" "$(basename "$0")" >>"$CHECK_TOOLING_LOG"' \
        >"${TMP_DIR}/tests/validation/${contract}"
    chmod 0700 "${TMP_DIR}/tests/validation/${contract}"
done
# Fixture expands the variable when invoked.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "script:release-contract.sh\n" >>"$CHECK_TOOLING_LOG"' \
    >"${TMP_DIR}/scripts/release-contract.sh"
chmod 0700 "${TMP_DIR}/scripts/release-contract.sh"

: >"${TMP_DIR}/release.log"
CHECK_TOOLING_LOG="${TMP_DIR}/release.log" \
PATH="${TMP_DIR}/bin:/usr/bin:/bin" "${TMP_DIR}/scripts/check.sh" --release \
    >"${TMP_DIR}/release.stdout" 2>"${TMP_DIR}/release.stderr"
for generated in \
    inventory/hosts.yml \
    group_vars/all/vars.yml \
    group_vars/all/vault_services.yml \
    group_vars/all/vault_ssh.yml; do
    [[ ! -e ${TMP_DIR}/${generated} ]] || {
        printf 'check-tooling: temporary example remained after success: %s\n' "${generated}" >&2
        exit 1
    }
done
printf '%s\n' \
    test:sbom-contract.sh \
    test:release-artifacts-contract.sh \
    test:release-workflow-contract.sh \
    test:release-publish-contract.sh \
    test:sbom-contract.sh \
    test:release-contract.sh \
    script:release-contract.sh >"${TMP_DIR}/release.expected"
cmp "${TMP_DIR}/release.expected" "${TMP_DIR}/release.log" || {
    printf 'check-tooling: --release did not run the exact release contract set\n' >&2
    exit 1
}

printf 'check-tooling: release mode dispatch PASS\n'

[[ ${regression_failures} -eq 0 ]] || exit 1
