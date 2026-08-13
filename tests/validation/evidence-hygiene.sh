#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly TASK_NAMES=(
  metadata.env output-before.manifest task-1-ansible-runtime.log task-2-backup-sandbox.log
  task-3-release-contract.log task-4-installer-contract.log task-5-ssh-ufw-qemu.log
  task-6-restore-sandbox.log task-6-restore-drill.log task-7-compose-render.log
  task-7-bootstrap-qemu.log task-8-cve-route.log task-9-health.log task-10-domain-caddy.log
  task-11-local-qemu.log task-11-remote-qemu.log task-11-negative.log task-12-local.log
  task-12-workflow.json task-13-doc-contract.log push-authorization.json git-transition.json dispatch.json
  task-14-workflow.json task-14-workflow.log task-14-vps.log task-14-release-candidate.md pr.json
  output-after.manifest
)
readonly FINAL_NAMES=(F1-report.txt F2-report.txt F3-report.txt F3-cleanup.log F4-report.txt F4-pages.manifest)
readonly META_KEYS=(tested_sha original_root task_root base_sha started_at_utc completed_at_utc)

fail() { printf 'FAIL evidence-hygiene:%s\n' "$1" >&2; return 1; }

usage() {
  printf 'usage: %s --attempt-dir DIR --tested-sha SHA [--manifest-dir DIR] [--phase task|final]\n' "$0" >&2
  printf '       %s --self-test\n' "$0" >&2
}

is_sha() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }
is_rfc3339() { [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; }

check_descriptor() {
  local path=$1 kind mode links got
  [[ ! -L $path && -f $path ]] || fail descriptor || return
  got=$(stat -c '%F:%a:%h' -- "$path") || { fail descriptor; return; }
  IFS=: read -r kind mode links <<<"$got"
  [[ $kind == 'regular file' && $mode == 600 && $links == 1 ]] || fail descriptor
}

check_manifest() {
  local manifest=$1; shift
  local -a expected=("$@") actual=()
  local line kind mode links got
  [[ ! -L $manifest && -f $manifest ]] || { fail manifest-descriptor; return; }
  got=$(stat -c '%F:%a:%h' -- "$manifest") || { fail manifest-descriptor; return; }
  IFS=: read -r kind mode links <<<"$got"
  [[ $kind == 'regular file' && $mode == 644 && $links == 1 ]] || { fail manifest-descriptor; return; }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { fail manifest-schema; return; }
    actual+=("$line")
  done < "$manifest"
  ((${#actual[@]} == ${#expected[@]})) || { fail manifest-completeness; return; }
  local i
  for i in "${!expected[@]}"; do
    [[ ${actual[i]} == "${expected[i]}" ]] || { fail manifest-lifecycle; return; }
  done
}

check_metadata() {
  local path=$1 expected_sha=$2 line key value
  local -A seen=()
  check_descriptor "$path" || return
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([a-z_]+)=(.*)$ ]] || { fail metadata-schema; return; }
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    [[ -z ${seen[$key]+x} ]] || { fail metadata-duplicate; return; }
    seen[$key]=$value
  done < "$path"
  ((${#seen[@]} == ${#META_KEYS[@]})) || { fail metadata-keys; return; }
  local required
  for required in "${META_KEYS[@]}"; do [[ -n ${seen[$required]+x} ]] || { fail metadata-keys; return; }; done
  if [[ ${seen[tested_sha]} != "$expected_sha" ]] || ! is_sha "${seen[tested_sha]}"; then
    fail sha-binding
    return
  fi
  is_sha "${seen[base_sha]}" || { fail metadata-format; return; }
  [[ ${seen[original_root]} == /* && ${seen[task_root]} == /* && ${seen[original_root]} != *$'\n'* && ${seen[task_root]} != *$'\n'* ]] || { fail metadata-format; return; }
  if ! is_rfc3339 "${seen[started_at_utc]}" || ! is_rfc3339 "${seen[completed_at_utc]}"; then
    fail metadata-format
  fi
}

check_sha_receipt() {
  local path=$1 expected_sha=$2
  case ${path##*.} in
    json)
      LC_ALL=C grep -E -q -- "\"tested_sha\"[[:space:]]*:[[:space:]]*\"${expected_sha}\"" "$path"
      ;;
    *)
      LC_ALL=C grep -F -x -q -- "tested_sha=${expected_sha}" "$path"
      ;;
  esac || fail sha-binding
}

contains_secret_pattern() {
  local path=$1
  LC_ALL=C grep -E -q -- \
    '-----BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----|AGE-SECRET-KEY-|(^|[[:space:]])(PrivateKey|PresharedKey|INIT_PASSWORD|ZERO_TRUST_[A-Z0-9_]*PASSWORD)[[:space:]]*=' \
    "$path" && return 0
  LC_ALL=C grep -Ei -q -- '(^|[[:space:]])[A-Za-z_][A-Za-z0-9_]*(token|secret|credential|password|api_key)[[:space:]]*=[[:space:]]*[^<[:space:]][^[:space:]]*' "$path"
}

check_tree() {
  local dir=$1 phase=$2 sha=$3 name path
  [[ ! -L $dir && -d $dir ]] || { fail attempt-descriptor; return; }
  local -a allowed=("${TASK_NAMES[@]}")
  [[ $phase == final ]] && allowed+=("${FINAL_NAMES[@]}")
  local -A permitted=()
  for name in "${allowed[@]}"; do permitted[$name]=1; done
  while IFS= read -r -d '' path; do
    name=${path##*/}
    [[ -n ${permitted[$name]+x} ]] || { fail unsafe-artifact; return; }
  done < <(find -P "$dir" -mindepth 1 -maxdepth 1 -print0)
  for name in "${allowed[@]}"; do
    path="$dir/$name"
    check_descriptor "$path" || return
    contains_secret_pattern "$path" && { fail secret-pattern; return; }
    case $name in
      metadata.env|output-before.manifest|output-after.manifest|push-authorization.json) ;;
      *) check_sha_receipt "$path" "$sha" || return ;;
    esac
  done
  cmp -s "$dir/output-before.manifest" "$dir/output-after.manifest" || { fail output-drift; return; }
  check_metadata "$dir/metadata.env" "$sha"
}

validate() {
  local attempt=$1 sha=$2 manifest_dir=$3 phase=$4
  is_sha "$sha" || { fail argument; return; }
  check_manifest "$manifest_dir/evidence-manifest.txt" "${TASK_NAMES[@]}" || return
  check_manifest "$manifest_dir/final-evidence-manifest.txt" "${FINAL_NAMES[@]}" || return
  check_tree "$attempt" "$phase" "$sha"
}

write_contract_manifests() {
  local destination=$1 name
  : > "$destination/evidence-manifest.txt"
  for name in "${TASK_NAMES[@]}"; do printf '%s\n' "$name" >> "$destination/evidence-manifest.txt"; done
  : > "$destination/final-evidence-manifest.txt"
  for name in "${FINAL_NAMES[@]}"; do printf '%s\n' "$name" >> "$destination/final-evidence-manifest.txt"; done
  chmod 644 "$destination/evidence-manifest.txt" "$destination/final-evidence-manifest.txt"
}

write_positive_tree() {
  local destination=$1 sha=$2 name
  for name in "${TASK_NAMES[@]}" "${FINAL_NAMES[@]}"; do
    if [[ $name == metadata.env ]]; then
      printf 'tested_sha=%s\noriginal_root=/safe/original\ntask_root=/safe/task\nbase_sha=%040d\nstarted_at_utc=2026-08-13T00:00:00Z\ncompleted_at_utc=2026-08-13T00:00:01Z\n' "$sha" 0 > "$destination/$name"
    elif [[ $name == output-before.manifest || $name == output-after.manifest ]]; then
      printf 'format\0zt-output-manifest-v1\0fixture\0' > "$destination/$name"
    elif [[ $name == *.json ]]; then
      printf '{"tested_sha":"%s","sanitized":true}\n' "$sha" > "$destination/$name"
    else
      printf 'tested_sha=%s\nsanitized=true\n' "$sha" > "$destination/$name"
    fi
    chmod 600 "$destination/$name"
  done
}

expect_reject() {
  local label=$1 expected_code=$2; shift 2
  local output rc
  set +e
  output=$("$@" 2>&1); rc=$?
  set -e
  [[ $rc -ne 0 && $output == *"FAIL evidence-hygiene:$expected_code"* ]] || { printf 'FAIL self-test:%s\n' "$label" >&2; return 1; }
  [[ $output != *AGE-SECRET-KEY-* && $output != *PRIVATE\ KEY* && $output != *fixturecredential* ]] || { printf 'FAIL self-test:sanitized-diagnostic\n' >&2; return 1; }
  printf 'PASS negative-%s\n' "$label"
}

self_test() {
  local sha=0123456789abcdef0123456789abcdef01234567 pause=${EVIDENCE_HYGIENE_SELF_TEST_PAUSE_SECONDS:-0}
  [[ $pause =~ ^[0-9]+$ && $pause -le 5 ]] || { fail argument; return; }
  SELF_TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/evidence-hygiene.XXXXXX")
  trap 'rm -rf -- "${SELF_TEST_TEMP:-}"' EXIT HUP INT TERM
  mkdir -m 700 "$SELF_TEST_TEMP/attempt" "$SELF_TEST_TEMP/manifests"
  write_contract_manifests "$SELF_TEST_TEMP/manifests"
  write_positive_tree "$SELF_TEST_TEMP/attempt" "$sha"
  sleep "$pause"
  validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  printf 'PASS positive\n'

  printf 'mutation\0' >> "$SELF_TEST_TEMP/attempt/output-after.manifest"
  expect_reject output-drift output-drift validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  cp "$SELF_TEST_TEMP/attempt/output-before.manifest" "$SELF_TEST_TEMP/attempt/output-after.manifest"
  chmod 600 "$SELF_TEST_TEMP/attempt/output-after.manifest"
  printf 'PASS output-lifecycle\n'

  rm -f -- "$SELF_TEST_TEMP/attempt/task-1-ansible-runtime.log"
  expect_reject missing-file descriptor validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  printf 'tested_sha=%s\nsanitized=true\n' "$sha" > "$SELF_TEST_TEMP/attempt/task-1-ansible-runtime.log"; chmod 600 "$SELF_TEST_TEMP/attempt/task-1-ansible-runtime.log"
  chmod 644 "$SELF_TEST_TEMP/attempt/task-2-backup-sandbox.log"
  expect_reject wrong-mode descriptor validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  chmod 600 "$SELF_TEST_TEMP/attempt/task-2-backup-sandbox.log"
  rm -f -- "$SELF_TEST_TEMP/attempt/task-3-release-contract.log"; ln -s task-2-backup-sandbox.log "$SELF_TEST_TEMP/attempt/task-3-release-contract.log"
  expect_reject symlink descriptor validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  rm -f -- "$SELF_TEST_TEMP/attempt/task-3-release-contract.log"; printf 'tested_sha=%s\nsanitized=true\n' "$sha" > "$SELF_TEST_TEMP/attempt/task-3-release-contract.log"; chmod 600 "$SELF_TEST_TEMP/attempt/task-3-release-contract.log"
  rm -f -- "$SELF_TEST_TEMP/attempt/task-4-installer-contract.log"; ln "$SELF_TEST_TEMP/attempt/task-3-release-contract.log" "$SELF_TEST_TEMP/attempt/task-4-installer-contract.log"
  expect_reject hardlink descriptor validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  rm -f -- "$SELF_TEST_TEMP/attempt/task-4-installer-contract.log"; printf 'tested_sha=%s\nsanitized=true\n' "$sha" > "$SELF_TEST_TEMP/attempt/task-4-installer-contract.log"; chmod 600 "$SELF_TEST_TEMP/attempt/task-4-installer-contract.log"
  printf 'PASS descriptor-mode-link\n'

  printf 'extra.log\n' >> "$SELF_TEST_TEMP/manifests/evidence-manifest.txt"
  expect_reject extra-manifest manifest-completeness validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  write_contract_manifests "$SELF_TEST_TEMP/manifests"
  sed -i '$d' "$SELF_TEST_TEMP/manifests/evidence-manifest.txt"
  expect_reject missing-manifest manifest-completeness validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  write_contract_manifests "$SELF_TEST_TEMP/manifests"; printf 'unsafe=true\n' > "$SELF_TEST_TEMP/attempt/unsafe.log"; chmod 600 "$SELF_TEST_TEMP/attempt/unsafe.log"
  expect_reject extra-artifact unsafe-artifact validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  rm -f -- "$SELF_TEST_TEMP/attempt/unsafe.log"
  printf 'PASS manifest-completeness\n'

  sed -i '/base_sha/d' "$SELF_TEST_TEMP/attempt/metadata.env"
  expect_reject missing-metadata metadata-keys validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  write_positive_tree "$SELF_TEST_TEMP/attempt" "$sha"; printf 'tested_sha=%s\n' "$sha" >> "$SELF_TEST_TEMP/attempt/metadata.env"
  expect_reject duplicate-metadata metadata-duplicate validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  write_positive_tree "$SELF_TEST_TEMP/attempt" "$sha"
  printf 'PASS metadata\n'

  sed -i 's/^tested_sha=.*/tested_sha=ffffffffffffffffffffffffffffffffffffffff/' "$SELF_TEST_TEMP/attempt/metadata.env"
  expect_reject wrong-sha sha-binding validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  write_positive_tree "$SELF_TEST_TEMP/attempt" "$sha"
  printf 'PASS sha-binding\n'

  sed -i '/^tested_sha=/d' "$SELF_TEST_TEMP/attempt/task-1-ansible-runtime.log"
  expect_reject missing-receipt-sha sha-binding validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  write_positive_tree "$SELF_TEST_TEMP/attempt" "$sha"

  for name in private-key age-identity credential; do
    case $name in
      private-key) printf '%s\n' '-----BEGIN PRIVATE KEY-----' ;;
      age-identity) printf '%s\n' 'AGE-SECRET-KEY-TESTFIXTURE' ;;
      credential) printf '%s\n' 'API_TOKEN=fixturecredential' ;;
    esac > "$SELF_TEST_TEMP/attempt/task-1-ansible-runtime.log"
    chmod 600 "$SELF_TEST_TEMP/attempt/task-1-ansible-runtime.log"
    expect_reject "$name" secret-pattern validate "$SELF_TEST_TEMP/attempt" "$sha" "$SELF_TEST_TEMP/manifests" final
  done
  printf 'PASS secret-rejection\n'
  rm -rf -- "$SELF_TEST_TEMP"; SELF_TEST_TEMP=''; trap - EXIT HUP INT TERM
  printf 'PASS cleanup\n'
}

main() {
  local attempt='' sha='' manifest_dir=$SCRIPT_DIR phase=final
  if (($# == 1)) && [[ $1 == --self-test ]]; then self_test; return; fi
  while (($#)); do
    case $1 in
      --attempt-dir) attempt=${2-}; shift 2 ;;
      --tested-sha) sha=${2-}; shift 2 ;;
      --manifest-dir) manifest_dir=${2-}; shift 2 ;;
      --phase) phase=${2-}; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  [[ -n $attempt && -n $sha && ( $phase == task || $phase == final ) ]] || { usage; return 2; }
  validate "$attempt" "$sha" "$manifest_dir" "$phase"
  printf 'PASS evidence-hygiene\n'
}

main "$@"
