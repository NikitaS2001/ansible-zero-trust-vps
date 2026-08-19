#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPOSITORY_ROOT=${WORKFLOW_CONTRACT_ROOT:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}
readonly REPOSITORY_ROOT
readonly DEFAULT_MANIFEST="${SCRIPT_DIR}/manifest.txt"
readonly -a EXPECTED_MANIFEST=(
    'ansible-runtime.sh|'
    'backup-sandbox.sh|'
    'release-contract.sh|'
    'installer-contract.sh|'
    'restore-sandbox.sh|'
    'compose-render.sh|'
    'workflow-contract.sh|--self-test'
    'output-manifest.sh|--self-test'
    'evidence-hygiene.sh|--self-test'
    'github-terminal-audit.sh|--self-test'
)
readonly BASH_SYNTAX_COMMAND='bash -n install.sh scripts/*.sh tests/validation/*.sh tests/e2e/*.sh'
readonly SHELLCHECK_COMMAND='shellcheck install.sh scripts/*.sh tests/validation/*.sh tests/e2e/*.sh'
readonly MANIFEST_RUNNER_COMMAND='tests/validation/workflow-contract.sh .github/workflows/security.yml'

RUN_LOG_DIR=''
SELF_TEST_DIR=''

fail() {
    printf 'workflow-contract: %s\n' "$*" >&2
    return 1
}

cleanup() {
    if [[ -n ${RUN_LOG_DIR} && -d ${RUN_LOG_DIR} ]]; then
        find "${RUN_LOG_DIR}" -depth -delete
    fi
    if [[ -n ${SELF_TEST_DIR} && -d ${SELF_TEST_DIR} ]]; then
        find "${SELF_TEST_DIR}" -depth -delete
    fi
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

usage() {
    printf 'usage: %s WORKFLOW_PATH\n       %s --self-test\n' "$0" "$0" >&2
}

validate_manifest() {
    local manifest_path="$1"
    local line script arguments index=0
    local -A seen=()

    [[ -f ${manifest_path} && ! -L ${manifest_path} ]] || fail "manifest is not a regular file: ${manifest_path}"
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} =~ ^([A-Za-z0-9][A-Za-z0-9._-]*\.sh)\|([^\|]*)$ ]] || fail "malformed manifest entry: ${line}"
        script=${BASH_REMATCH[1]}
        arguments=${BASH_REMATCH[2]}
        [[ ${arguments} == '' || ${arguments} == '--self-test' ]] || fail "unsupported manifest arguments: ${line}"
        [[ -z ${seen[${line}]+x} ]] || fail "duplicate manifest entry: ${line}"
        seen[${line}]=1
        (( index < ${#EXPECTED_MANIFEST[@]} )) || fail 'manifest has extra entries'
        [[ ${line} == "${EXPECTED_MANIFEST[index]}" ]] || fail "manifest entry does not match the literal contract: ${line}"
        ((index += 1))
    done <"${manifest_path}"
    (( index == ${#EXPECTED_MANIFEST[@]} )) || fail 'manifest is incomplete'
}

validate_no_live_vps_workflow() {
    [[ ! -e "${REPOSITORY_ROOT}/.github/workflows/e2e-public-install.yml" && ! -L "${REPOSITORY_ROOT}/.github/workflows/e2e-public-install.yml" ]] || fail 'live VPS workflow remains'
}

validate_workflow() {
    local workflow_path="$1"

    [[ -f ${workflow_path} && ! -L ${workflow_path} ]] || fail "workflow is not a regular file: ${workflow_path}"
    WORKFLOW_PATH="${workflow_path}" \
        CONTRACT_BASH_SYNTAX_COMMAND="${BASH_SYNTAX_COMMAND}" \
        CONTRACT_SHELLCHECK_COMMAND="${SHELLCHECK_COMMAND}" \
        CONTRACT_MANIFEST_RUNNER_COMMAND="${MANIFEST_RUNNER_COMMAND}" \
        python3 - <<'PY'
from pathlib import Path
import os
import sys
import yaml

def reject(message: str) -> None:
    print(f"workflow-contract: {message}", file=sys.stderr)
    raise SystemExit(1)

try:
    document = yaml.safe_load(Path(os.environ["WORKFLOW_PATH"]).read_text(encoding="utf-8"))
except (OSError, yaml.YAMLError) as error:
    reject(f"workflow did not safe-load: {error}")
if not isinstance(document, dict):
    reject("workflow root is not a mapping")
jobs = document.get("jobs")
if not isinstance(jobs, dict):
    reject("workflow jobs is not a mapping")
job = jobs.get("lint-and-scan")
if not isinstance(job, dict):
    reject("workflow lint-and-scan job is not a mapping")
steps = job.get("steps")
if not isinstance(steps, list):
    reject("workflow steps is not a list")

runs: list[str] = []
manifest_runner_steps = 0
for index, step in enumerate(steps):
    if not isinstance(step, dict):
        reject(f"workflow step {index} is not a mapping")
    if "run" not in step:
        continue
    run = step["run"]
    if not isinstance(run, str):
        reject(f"workflow step {index} has a non-string run")
    runs.append(run)
    if step.get("name") == "Run validation manifest" and run == os.environ["CONTRACT_MANIFEST_RUNNER_COMMAND"]:
        manifest_runner_steps += 1

if manifest_runner_steps != 1:
    reject("workflow lacks exactly one explicit normal manifest-runner step")
for command in (os.environ["CONTRACT_BASH_SYNTAX_COMMAND"], os.environ["CONTRACT_SHELLCHECK_COMMAND"]):
    if runs.count(command) != 1:
        reject(f"workflow lacks exactly one complete static command: {command}")
PY
}

run_manifest_command() {
    env \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=commit.gpgSign \
        GIT_CONFIG_VALUE_0=false \
        "$@"
}

run_manifest() {
    local manifest_path="$1"
    local line script arguments
    local -a command

    while IFS= read -r line || [[ -n ${line} ]]; do
        script=${line%%|*}
        [[ -x ${SCRIPT_DIR}/${script} ]] || fail "manifest target is not executable: ${script}"
    done <"${manifest_path}"

    RUN_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workflow-contract.XXXXXX")"
    chmod 0700 "${RUN_LOG_DIR}"
    while IFS= read -r line || [[ -n ${line} ]]; do
        script=${line%%|*}
        arguments=${line#*|}
        command=("${SCRIPT_DIR}/${script}")
        if [[ ${arguments} == '--self-test' ]]; then
            command+=("${arguments}")
        fi
        run_manifest_command "${command[@]}" >"${RUN_LOG_DIR}/${script}.stdout" 2>"${RUN_LOG_DIR}/${script}.stderr" || {
            fail "manifest invocation failed: ${line}"
            return 1
        }
    done <"${manifest_path}"
}

run_contract() {
    local workflow_path="$1"
    local manifest_path="${WORKFLOW_CONTRACT_MANIFEST:-${DEFAULT_MANIFEST}}"

    validate_no_live_vps_workflow
    validate_manifest "${manifest_path}"
    validate_workflow "${workflow_path}"
    run_manifest "${manifest_path}"
    printf '{"manifest_complete":true,"workflow_parsed":true,"static_contract_complete":true,"invocation_count":10}\n'
}

expect_rejection() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "self-test accepted ${description}"
    fi
}

write_valid_fixture() {
    local manifest_path="$1" workflow_path="$2"
    printf '%s\n' "${EXPECTED_MANIFEST[@]}" >"${manifest_path}"
    cat >"${workflow_path}" <<EOF
---
name: security
'on':
  pull_request:
jobs:
  lint-and-scan:
    steps:
      - name: Bash syntax
        run: ${BASH_SYNTAX_COMMAND}
      - name: Shellcheck
        run: ${SHELLCHECK_COMMAND}
      - name: Run validation manifest
        run: ${MANIFEST_RUNNER_COMMAND}
EOF
}

self_test() {
    local fixture_dir manifest_path workflow_path hostile_git_config
    SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workflow-contract-self-test.XXXXXX")"
    chmod 0700 "${SELF_TEST_DIR}"
    fixture_dir="${SELF_TEST_DIR}"
    manifest_path="${fixture_dir}/manifest.txt"
    workflow_path="${fixture_dir}/security.yml"
    write_valid_fixture "${manifest_path}" "${workflow_path}"
    validate_workflow "${workflow_path}"

    mkdir -p "${fixture_dir}/.github/workflows"
    printf '%s\n' 'name: e2e-public-install' 'env:' "  E2E_VPS_TOKEN: \${{ secrets.E2E_VPS_TOKEN }}" >"${fixture_dir}/.github/workflows/e2e-public-install.yml"
    expect_rejection 'live VPS workflow ingress' env WORKFLOW_CONTRACT_ROOT="${fixture_dir}" WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    find "${fixture_dir}/.github" -depth -delete

    sed -i 's#tests/validation/workflow-contract.sh .github/workflows/security.yml#true#' "${workflow_path}"
    expect_rejection 'missing invocation' env WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    write_valid_fixture "${manifest_path}" "${workflow_path}"
    printf '%s\n' 'github-terminal-audit.sh|--self-test' >>"${manifest_path}"
    expect_rejection 'duplicate entry' env WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    write_valid_fixture "${manifest_path}" "${workflow_path}"
    sed -i 's/github-terminal-audit.sh|--self-test/github-terminal-audit.sh|--changed/' "${manifest_path}"
    expect_rejection 'changed arguments' env WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    write_valid_fixture "${manifest_path}" "${workflow_path}"
    sed -i 's/github-terminal-audit.sh|--self-test/github-terminal-audit.sh/' "${manifest_path}"
    expect_rejection 'malformed delimiter' env WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    write_valid_fixture "${manifest_path}" "${workflow_path}"
    printf '%s\n' 'jobs: [broken' >"${workflow_path}"
    expect_rejection 'invalid YAML' env WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    write_valid_fixture "${manifest_path}" "${workflow_path}"
    sed -i 's#run: tests/validation/workflow-contract.sh .github/workflows/security.yml#run: [tests/validation/workflow-contract.sh]#' "${workflow_path}"
    expect_rejection 'non-string run' env WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    write_valid_fixture "${manifest_path}" "${workflow_path}"
    sed -i 's#shellcheck install.sh scripts/\*.sh tests/validation/\*.sh tests/e2e/\*.sh#shellcheck install.sh scripts/*.sh#' "${workflow_path}"
    expect_rejection 'incomplete static command' env WORKFLOW_CONTRACT_MANIFEST="${manifest_path}" "$0" "${workflow_path}"
    hostile_git_config="${fixture_dir}/hostile.gitconfig"
    printf '[commit]\n\tgpgSign = true\n' >"${hostile_git_config}"
    if ! GIT_CONFIG_GLOBAL="${hostile_git_config}" run_manifest_command "${SCRIPT_DIR}/release-contract.sh" --case pr-valid >/dev/null; then
        fail 'self-test rejected manifest child under hostile global Git signing'
    fi
    find "${fixture_dir}" -depth -delete
    SELF_TEST_DIR=''
    printf 'workflow-contract self-test: PASS\n' >&2
}

main() {
    if [[ ${1:-} == '--self-test' && $# -eq 1 ]]; then
        self_test
        return
    fi
    [[ $# -eq 1 ]] || { usage; return 2; }
    run_contract "$1"
}

main "$@"
