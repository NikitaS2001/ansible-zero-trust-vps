#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qemu-source-contract.XXXXXX")"
readonly TMP_DIR
trap 'find "${TMP_DIR}" -depth -delete' EXIT

git -C "${TMP_DIR}" init -q -b main
printf 'kept\n' >"${TMP_DIR}/kept"
printf 'deleted\n' >"${TMP_DIR}/deleted"
git -C "${TMP_DIR}" add kept deleted
git -C "${TMP_DIR}" -c user.name=test -c user.email=test.invalid \
    commit -qm fixture
find "${TMP_DIR}/deleted" -delete
printf 'untracked\n' >"${TMP_DIR}/untracked"

mapfile -d '' -t paths < <(
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-source-list "${TMP_DIR}"
)
printf '%s\n' "${paths[@]}" | sort >"${TMP_DIR}/actual"
printf '%s\n' kept untracked >"${TMP_DIR}/expected"
cmp "${TMP_DIR}/expected" "${TMP_DIR}/actual" || {
    printf 'qemu-source-contract: source list included a deletion or lost an existing path\n' >&2
    exit 1
}

fresh_env="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-installer-env fresh)"
for credential in \
    ZERO_TRUST_ADMIN_PASSWORD \
    ZERO_TRUST_ADGUARD_PASSWORD \
    ZERO_TRUST_WG_PASSWORD \
    ZERO_TRUST_SSH_PUBKEY; do
    [[ ${fresh_env} == *"${credential}="* ]] \
        || { printf 'qemu-source-contract: fresh install omitted %s\n' "${credential}" >&2; exit 1; }
done
bash -c "env ${fresh_env} sh -c '\
    test \"\$ZERO_TRUST_ADMIN_PASSWORD\" = \"admin'\''secret\" && \
    test \"\$ZERO_TRUST_ADGUARD_PASSWORD\" = \"adguard secret\" && \
    test \"\$ZERO_TRUST_WG_PASSWORD\" = '\''wg\$secret'\'' && \
    test \"\$ZERO_TRUST_SSH_PUBKEY\" = \"ssh-ed25519 AAAA fixture\"'" || {
    printf 'qemu-source-contract: fresh credential environment did not round-trip\n' >&2
    exit 1
}
existing_env="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-installer-env existing)"
[[ -z ${existing_env} ]] || {
    printf 'qemu-source-contract: existing-state rerun exposed credential inputs\n' >&2
    exit 1
}
[[ "$(grep -c 'id_ed25519" existing' "${ROOT_DIR}/tests/e2e/qemu-install.sh")" -eq 3 ]] || {
    printf 'qemu-source-contract: retry paths are not explicitly existing-state reruns\n' >&2
    exit 1
}
grep -Fq "'sudo cat /opt/zero-trust-vps/.wg-traffic-mode'" \
    "${ROOT_DIR}/tests/e2e/common.sh" || {
    printf 'qemu-source-contract: traffic mode must be read with privilege\n' >&2
    exit 1
}
grep -Fq "sh -c 'cd /opt/zero-trust-vps-installer/repo" \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" || {
    printf 'qemu-source-contract: root-only installer checkout must be entered with privilege\n' >&2
    exit 1
}
grep -Fq -- '--extra-vars @/etc/zero-trust-vps/installer-vault.yml' \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" || {
    printf 'qemu-source-contract: direct playbook runs must load encrypted installer state\n' >&2
    exit 1
}

printf 'qemu-source-contract: source filter and credential-free rerun PASS\n'
