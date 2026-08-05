#!/usr/bin/env bash
# Shared helpers for tests/e2e/*.sh
set -euo pipefail

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

run_remote() {
    local target="$1"; shift
    local port="$1"; shift
    local key="$1"; shift
    ssh -p "${port}" -i "${key}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        "${target}" "$@"
}

run_remote_stdin() {
    local target="$1"; shift
    local port="$1"; shift
    local key="$1"; shift
    ssh -p "${port}" -i "${key}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        "${target}" "$@"
}

require_ssh_down() {
    local target="$1"; local port="$2"; local key="$3"; local retries="${4:-30}"
    local i=0
    while ssh -p "${port}" -i "${key}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 -o BatchMode=yes \
        "${target}" 'true' >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ "${i}" -ge "${retries}" ]]; then
            fail "SSH on ${target}:${port} did not go down (expected after reboot)"
        fi
        sleep 3
    done
}

require_ssh_ready() {
    local target="$1"; local port="$2"; local key="$3"; local retries="${4:-30}"
    local i=0
    while ! ssh -p "${port}" -i "${key}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o BatchMode=yes \
        "${target}" 'true' >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ "${i}" -ge "${retries}" ]]; then
            fail "SSH did not become ready on ${target}:${port}"
        fi
        sleep 5
    done
}

# verify_deployment target port key
verify_deployment() {
    local target="$1"; local port="$2"; local key="$3"
    local ssh_port="${E2E_SSH_PORT:-2222}"
    local wg_port="${E2E_WG_PORT:-51820}"
    local out

    echo "[check] SSH on hardened port ${port} works with the admin key"
    run_remote "${target}" "${port}" "${key}" 'echo ssh-ok' >/dev/null
    pass "SSH ${target}:${port}"

    echo "[check] UFW is active"
    out="$(run_remote "${target}" "${port}" "${key}" 'sudo ufw status verbose')"
    grep -q 'Status: active' <<<"${out}" || fail "UFW is not active"

    echo "[check] UFW allows SSH ${ssh_port}/tcp and WireGuard ${wg_port}/udp"
    out="$(run_remote "${target}" "${port}" "${key}" 'sudo ufw status')"
    grep -q "${ssh_port}/tcp" <<<"${out}" || fail "SSH port ${ssh_port}/tcp missing from UFW"
    grep -q "${wg_port}/udp" <<<"${out}" || fail "WireGuard port ${wg_port}/udp missing from UFW"
    pass "UFW rules"

    echo "[check] wg-easy, adguard and caddy containers are running"
    out="$(run_remote "${target}" "${port}" "${key}" 'sudo docker ps --format "{{.Names}} {{.Status}}"')"
    for c in wg-easy adguard caddy; do
        grep -q "^${c} " <<<"${out}" || fail "container ${c} is not running"
    done
    pass "containers up"

    echo "[check] WireGuard interface is up inside wg-easy"
    run_remote "${target}" "${port}" "${key}" 'sudo docker exec wg-easy wg show' >/dev/null
    pass "WireGuard interface"

    echo "[check] wg-easy admin API enforces authentication (expect 401)"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:51821/api/session')"
    [[ "${out}" == "401" ]] || fail "wg-easy /api/session returned ${out}, expected 401"
    pass "wg-easy auth enforced"

    echo "[check] AdGuard admin UI responds (200 or 401)"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/control/status')"
    [[ "${out}" == "200" || "${out}" == "401" ]] || fail "AdGuard status returned ${out}"
    pass "AdGuard UI"

    echo "[check] no container publishes a TCP port on 0.0.0.0"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'sudo docker ps --format "{{.Names}} {{.Ports}}"')"
    if grep -qE '0\.0\.0\.0:[0-9]+->[0-9]+/tcp' <<<"${out}"; then
        fail "a container publishes a TCP port on 0.0.0.0: ${out}"
    fi
    pass "no public TCP exposure"

    echo "[check] the deployed Compose file contains no panel password"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'sudo grep -q INIT_PASSWORD /opt/zero-trust-vps/docker-compose.yml 2>/dev/null && echo PRESENT || echo CLEAN')"
    [[ "${out}" == "CLEAN" ]] || fail "docker-compose.yml still contains INIT_PASSWORD"
    pass "compose file is free of the panel password"
}
