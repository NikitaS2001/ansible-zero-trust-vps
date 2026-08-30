#!/usr/bin/env bash
# Runs the production UFW-Docker tasks through Ansible with command-boundary fakes.
set -euo pipefail

CASE=all
if [[ $# -gt 0 ]]; then
    [[ $# -eq 2 && "$1" = --case ]] || { echo "usage: $0 [--case all|convergence|duplicate-family|enable-failure|reload-failure|hung-ufw|hung-reload|cancel-resume|repeated-interruption|malformed]" >&2; exit 2; }
    CASE="$2"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-ufw-docker.XXXXXX")"
BIN="${TMP}/bin"
STATE="${TMP}/state"
PLAYBOOK="${TMP}/ufw-docker.yml"

cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "${BIN}"

cat >"${BIN}/ufw" <<'FAKE_UFW'
#!/bin/sh
set -eu
state="${FAKE_UFW_STATE:?}"
[ -f "${state}" ] || printf 'active=0\ninstall=0\nwg4=0\nwg6=0\nenable=0\nallow=0\nreload=0\n' >"${state}"
get() { sed -n "s/^$1=//p" "${state}"; }
set_value() { sed "s/^$1=.*/$1=$2/" "${state}" >"${state}.next" && mv "${state}.next" "${state}"; }
inc() { set_value "$1" "$(( $(get "$1") + 1 ))"; }
case "${1:-}" in
    status)
        [ "${FAKE_UFW_MALFORMED:-}" = status ] && { printf 'misleading success\n'; exit 0; }
        [ "$(get active)" = 1 ] && status=active || status=inactive
        printf 'Status: %s\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n' "${status}"
        ;;
    --force)
        [ "${2:-}" = enable ] || exit 2
        [ "${FAKE_UFW_HANG:-}" = enable ] && sleep 30
        [ "${FAKE_UFW_FAIL:-}" = enable ] && { printf 'injected enable failure\n' >&2; exit 1; }
        set_value active 1
        inc enable
        printf 'Firewall is active and enabled on system startup\n'
        ;;
    reload)
        [ "${FAKE_UFW_HANG:-}" = reload ] && sleep 30
        [ "${FAKE_UFW_FAIL:-}" = reload ] && { printf 'injected reload failure\n' >&2; exit 1; }
        inc reload
        printf 'Firewall reloaded\n'
        ;;
    *) printf 'unsupported fake ufw command: %s\n' "$*" >&2; exit 2 ;;
esac
FAKE_UFW

cat >"${BIN}/ufw-docker" <<'FAKE_UFW_DOCKER'
#!/bin/sh
set -eu
state="${FAKE_UFW_STATE:?}"
get() { sed -n "s/^$1=//p" "${state}"; }
set_value() { sed "s/^$1=.*/$1=$2/" "${state}" >"${state}.next" && mv "${state}.next" "${state}"; }
inc() { set_value "$1" "$(( $(get "$1") + 1 ))"; }
case "${1:-}" in
    install)
        if [ "$(get install)" = 0 ]; then
            set_value install 1
            printf 'Rules installed\n'
        fi
        ;;
    list)
        [ "${FAKE_UFW_MALFORMED:-}" = list ] && { printf 'misleading success\n'; exit 0; }
        if [ "${FAKE_UFW_DOCKER_DUPLICATE:-}" = v4 ]; then
            printf '[ 1] 51820/udp ALLOW FWD Anywhere # allow wg-easy 51820/udp\n'
            printf '[ 2] 51820/udp ALLOW FWD Anywhere # allow wg-easy 51820/udp\n'
            exit 0
        fi
        if [ "${FAKE_UFW_DOCKER_DUPLICATE:-}" = v6 ]; then
            printf '[ 1] 51820/udp (v6) ALLOW FWD Anywhere (v6) # allow wg-easy/v6 51820/udp\n'
            printf '[ 2] 51820/udp (v6) ALLOW FWD Anywhere (v6) # allow wg-easy/v6 51820/udp\n'
            exit 0
        fi
        found=0
        if [ "$(get wg4)" = 1 ]; then
            printf '[ 1] 51820/udp ALLOW FWD Anywhere # allow wg-easy 51820/udp\n'
            found=1
        fi
        if [ "$(get wg6)" = 1 ]; then
            printf '[ 2] 51820/udp (v6) ALLOW FWD Anywhere (v6) # allow wg-easy/v6 51820/udp\n'
            found=1
        fi
        [ "${found}" = 1 ]
        ;;
    allow)
        [ "${FAKE_UFW_HANG:-}" = allow ] && sleep 30
        before="$(get wg4)$(get wg6)"
        set_value wg4 1
        set_value wg6 1
        inc allow
        if [ "${before}" = 11 ]; then
            printf 'Skipping adding existing rule\n'
        else
            printf 'ufw route allow proto udp from any to 172.20.0.2 port 51820\nRule added\n'
        fi
        ;;
    *) printf 'unsupported fake ufw-docker command: %s\n' "$*" >&2; exit 2 ;;
esac
FAKE_UFW_DOCKER
chmod 0755 "${BIN}/ufw" "${BIN}/ufw-docker"

cat >"${PLAYBOOK}" <<EOF
---
- name: Exercise production UFW-Docker tasks
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_facts:
      virtualization_type: kvm
    vps_orchestration_enable_ufw_before_ufw_docker: true
    wg_container_port: 51820
  environment:
    PATH: "${BIN}:${PATH}"
  tasks:
    - import_role:
        name: ${ROOT}/roles/vps_orchestration
        tasks_from: ufw_docker.yml
EOF

run_play() {
    local name="$1"
    shift
    FAKE_UFW_STATE="${STATE}" "$@" ansible-playbook -i localhost, -c local "${PLAYBOOK}" \
        --start-at-task 'UFW-Docker | State | Read UFW status before enable' >"${TMP}/${name}.log" 2>&1
}

value() { sed -n "s/^$1=//p" "${STATE}"; }
expect_zero_change() {
    grep -Eq 'changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$1" || {
        sed -n '/PLAY RECAP/,$p' "$1" >&2
        exit 1
    }
}

reset_state() {
    printf 'active=0\ninstall=0\nwg4=0\nwg6=0\nenable=0\nallow=0\nreload=0\n' >"${STATE}"
}

drift() {
    sed "s/^$1=.*/$1=0/" "${STATE}" >"${STATE}.drift" && mv "${STATE}.drift" "${STATE}"
}

run_timeout_play() {
    local name="$1" seconds="$2"
    shift 2
    FAKE_UFW_STATE="${STATE}" timeout --kill-after=1s "${seconds}" "$@" ansible-playbook -i localhost, -c local "${PLAYBOOK}" \
        --start-at-task 'UFW-Docker | State | Read UFW status before enable' >"${TMP}/${name}.log" 2>&1
}

run_interrupt_play() {
    local name="$1"
    shift
    FAKE_UFW_STATE="${STATE}" setsid "$@" ansible-playbook -i localhost, -c local "${PLAYBOOK}" \
        --start-at-task 'UFW-Docker | State | Read UFW status before enable' >"${TMP}/${name}.log" 2>&1 &
    local pid=$!
    sleep 1
    kill -TERM -- "-${pid}"
    wait "${pid}"
}

seed_valid() {
    reset_state
    run_play first env
    [[ "$(value active)" = 1 && "$(value wg4)$(value wg6)" = 11 && "$(value enable)" = 1 && "$(value allow)" = 1 && "$(value reload)" = 2 ]]
}

convergence() {
    seed_valid
    run_play second env
    expect_zero_change "${TMP}/second.log"
    drift wg4
    run_play ipv4_drift env
    [[ "$(value wg4)$(value wg6)" = 11 && "$(value allow)" = 2 && "$(value reload)" = 3 ]]
    run_play after_ipv4_drift env
    expect_zero_change "${TMP}/after_ipv4_drift.log"
    drift wg6
    run_play ipv6_drift env
    [[ "$(value wg4)$(value wg6)" = 11 && "$(value allow)" = 3 && "$(value reload)" = 4 ]]
    run_play after_ipv6_drift env
    expect_zero_change "${TMP}/after_ipv6_drift.log"
    printf '[PASS] convergence valid repeat=0 ipv4=1->0 ipv6=1->0 enable=1 allow=3 reload=4\n'
}

duplicate_family() {
    seed_valid
    drift wg6
    if run_play duplicate_v4 env FAKE_UFW_DOCKER_DUPLICATE=v4; then
        echo '[FAIL] duplicate IPv4/missing IPv6 output was accepted' >&2
        exit 1
    fi
    grep -q 'Verify wg-easy WireGuard UDP rules' "${TMP}/duplicate_v4.log"
    if run_play duplicate_v6 env FAKE_UFW_DOCKER_DUPLICATE=v6; then
        echo '[FAIL] duplicate IPv6/missing IPv4 output was accepted' >&2
        exit 1
    fi
    printf '[PASS] duplicate-family output rejected by exact IPv4/IPv6 identity assertions\n'
}

enable_failure() {
    reset_state
    if run_play enable_failure env FAKE_UFW_FAIL=enable; then
        echo '[FAIL] enable failure was accepted' >&2
        exit 1
    fi
    grep -q 'injected enable failure' "${TMP}/enable_failure.log"
    [[ "$(value active)" = 0 && "$(value enable)" = 0 && "$(value reload)" = 0 ]]
    run_play enable_resume env
    [[ "$(value active)" = 1 && "$(value wg4)$(value wg6)" = 11 ]]
    printf '[PASS] enable failure failed closed then clean resume converged\n'
}

reload_failure() {
    seed_valid
    drift wg6
    if run_play reload_failure env FAKE_UFW_FAIL=reload; then
        echo '[FAIL] reload failure was accepted' >&2
        exit 1
    fi
    grep -q 'injected reload failure' "${TMP}/reload_failure.log"
    [[ "$(value active)" = 1 && "$(value wg4)$(value wg6)" = 11 && "$(value reload)" = 2 ]]
    run_play reload_resume env
    expect_zero_change "${TMP}/reload_resume.log"
    printf '[PASS] reload failure preserved active exact rules and bounded resume\n'
}

hung_ufw() {
    reset_state
    local rc
    set +e
    run_timeout_play hung_enable 2s env FAKE_UFW_HANG=enable
    rc=$?
    set -e
    if [[ "${rc}" = 0 ]]; then
        echo '[FAIL] hung enable was accepted' >&2
        exit 1
    fi
    [[ "${rc}" = 124 && "$(value active)" = 0 && "$(value enable)" = 0 ]]
    printf '[PASS] hung UFW enable bounded rc=124 with state unchanged\n'
}

hung_reload() {
    seed_valid
    drift wg6
    local rc
    set +e
    run_timeout_play hung_reload 2s env FAKE_UFW_HANG=reload
    rc=$?
    set -e
    if [[ "${rc}" = 0 ]]; then
        echo '[FAIL] hung reload was accepted' >&2
        exit 1
    fi
    [[ "${rc}" = 124 && "$(value active)" = 1 && "$(value wg4)$(value wg6)" = 11 && "$(value reload)" = 2 ]]
    printf '[PASS] hung reload bounded rc=124 with active exact rules preserved\n'
}

cancel_resume() {
    reset_state
    if run_interrupt_play interrupt_enable env FAKE_UFW_HANG=enable; then
        echo '[FAIL] interrupted enable was accepted' >&2
        exit 1
    fi
    [[ "$(value active)" = 0 && "$(value enable)" = 0 ]]
    seed_valid
    drift wg4
    if run_interrupt_play interrupt_rule env FAKE_UFW_HANG=allow; then
        echo '[FAIL] interrupted rule repair was accepted' >&2
        exit 1
    fi
    [[ "$(value wg4)" = 0 && "$(value wg6)" = 1 ]]
    run_play cancel_resume_success env
    [[ "$(value wg4)$(value wg6)" = 11 ]]
    printf '[PASS] cancel at enable/rule failed safely and resume repaired once\n'
}

repeated_interruption() {
    reset_state
    for attempt in one two; do
        if run_interrupt_play "interrupt_${attempt}" env FAKE_UFW_HANG=enable; then
            echo '[FAIL] repeated interrupted enable was accepted' >&2
            exit 1
        fi
        [[ "$(value active)" = 0 && "$(value enable)" = 0 && "$(value reload)" = 0 ]]
    done
    run_play repeated_resume env
    [[ "$(value active)" = 1 && "$(value wg4)$(value wg6)" = 11 ]]
    printf '[PASS] repeated interruption leaves no state residue and resume converges\n'
}

malformed() {
    seed_valid
    if run_play malformed env FAKE_UFW_MALFORMED=list; then
        echo '[FAIL] malformed list output was accepted' >&2
        exit 1
    fi
    grep -q 'misleading success' "${TMP}/malformed.log"
    printf '[PASS] malformed/misleading rule output rejected\n'
}

case "${CASE}" in
    all) convergence; duplicate_family; enable_failure; reload_failure; hung_ufw; hung_reload; cancel_resume; repeated_interruption; malformed ;;
    convergence) convergence ;;
    duplicate-family) duplicate_family ;;
    enable-failure) enable_failure ;;
    reload-failure) reload_failure ;;
    hung-ufw) hung_ufw ;;
    hung-reload) hung_reload ;;
    cancel-resume) cancel_resume ;;
    repeated-interruption) repeated_interruption ;;
    malformed) malformed ;;
    *) echo "unknown case: ${CASE}" >&2; exit 2 ;;
esac
