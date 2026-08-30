#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
readonly ROOT_DIR
readonly -a REQUIRED_VALIDATION_CONTRACTS=(
    secret-installer-contract.sh
    traffic-mode-contract.sh
    hardening-contract.sh
    orchestration-core.sh
    ufw-docker-idempotency.sh
    sbom-contract.sh
    fixture-git-signing-contract.sh
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
for contract in "${REQUIRED_VALIDATION_CONTRACTS[@]}"; do
    count="$(awk -F'|' -v contract="${contract}" '$1 == contract { count++ } END { print count + 0 }' \
        "${ROOT_DIR}/tests/validation/manifest.txt")"
    if [[ ${count} -ne 1 ]]; then
        printf 'check-tooling: required validation contract must appear exactly once: %s (found %s)\n' \
            "${contract}" "${count}" >&2
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
for contract in "${REQUIRED_VALIDATION_CONTRACTS[@]}"; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/validation/${contract}"
    chmod 0700 "${TMP_DIR}/tests/validation/${contract}"
done
chmod 0700 \
    "${TMP_DIR}/scripts/verify-ssot.sh" \
    "${TMP_DIR}/tests/validation/workflow-contract.sh" \
    "${TMP_DIR}/tests/validation/failing-contract.sh"
printf '%s|\n' "${REQUIRED_VALIDATION_CONTRACTS[@]}" \
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

printf '%s|\n' "${REQUIRED_VALIDATION_CONTRACTS[@]}" \
    >"${TMP_DIR}/tests/validation/manifest.complete"
manifest_rejection_failed=0
for contract in "${REQUIRED_VALIDATION_CONTRACTS[@]}"; do
    grep -Fvx -- "${contract}|" "${TMP_DIR}/tests/validation/manifest.complete" \
        >"${TMP_DIR}/tests/validation/manifest.txt"
    if PATH="${TMP_DIR}/bin:/usr/bin:/bin" "${TMP_DIR}/scripts/check.sh" \
        >"${TMP_DIR}/missing-${contract}.stdout" 2>"${TMP_DIR}/missing-${contract}.stderr"; then
        printf 'check-tooling: missing required validation contract succeeded: %s\n' \
            "${contract}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    elif ! grep -Fq -- "${contract}" "${TMP_DIR}/missing-${contract}.stderr"; then
        printf 'check-tooling: missing-contract failure did not name: %s\n' "${contract}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    else
        printf 'check-tooling: missing rejected and named: %s\n' "${contract}"
    fi

    sed "s|^${contract}|renamed-${contract}|" \
        "${TMP_DIR}/tests/validation/manifest.complete" \
        >"${TMP_DIR}/tests/validation/manifest.txt"
    if PATH="${TMP_DIR}/bin:/usr/bin:/bin" "${TMP_DIR}/scripts/check.sh" \
        >"${TMP_DIR}/renamed-${contract}.stdout" 2>"${TMP_DIR}/renamed-${contract}.stderr"; then
        printf 'check-tooling: renamed required validation contract succeeded: %s\n' \
            "${contract}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    elif ! grep -Fq -- "${contract}" "${TMP_DIR}/renamed-${contract}.stderr"; then
        printf 'check-tooling: renamed-contract failure did not name: %s\n' "${contract}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    else
        printf 'check-tooling: rename rejected and named: %s\n' "${contract}"
    fi

    cp -- "${TMP_DIR}/tests/validation/manifest.complete" \
        "${TMP_DIR}/tests/validation/manifest.txt"
    printf '%s|\n' "${contract}" >>"${TMP_DIR}/tests/validation/manifest.txt"
    if PATH="${TMP_DIR}/bin:/usr/bin:/bin" "${TMP_DIR}/scripts/check.sh" \
        >"${TMP_DIR}/duplicate-${contract}.stdout" 2>"${TMP_DIR}/duplicate-${contract}.stderr"; then
        printf 'check-tooling: duplicate required validation contract succeeded: %s\n' \
            "${contract}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    elif ! grep -Fq -- "${contract}" "${TMP_DIR}/duplicate-${contract}.stderr"; then
        printf 'check-tooling: duplicate-contract failure did not name: %s\n' "${contract}" >&2
        regression_failures=1
        manifest_rejection_failed=1
    else
        printf 'check-tooling: duplicate rejected and named: %s\n' "${contract}"
    fi
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

for contract in "${REQUIRED_VALIDATION_CONTRACTS[@]}"; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/validation/${contract}"
done

for tool in qemu-system-x86_64 qemu-img genisoimage; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/bin/${tool}"
    chmod 0700 "${TMP_DIR}/bin/${tool}"
done
printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/tests/validation/passing-contract.sh"
chmod 0700 "${TMP_DIR}/tests/validation/passing-contract.sh"
printf '%s|\n' "${REQUIRED_VALIDATION_CONTRACTS[@]}" \
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
