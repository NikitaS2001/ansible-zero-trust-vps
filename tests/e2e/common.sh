#!/usr/bin/env bash
# Shared helpers for tests/e2e/*.sh
set -euo pipefail

# Internal domain names, overridable via the environment for deployments that
# use a custom internal_domain_suffix.
WG_INTERNAL_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.internal}"
ADGUARD_INTERNAL_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"

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

record_ssh_host_key() {
    local host="$1" port="$2" known_hosts="$3"
    local scan_file
    scan_file="$(mktemp "${known_hosts}.scan.XXXXXX")"
    chmod 0600 "${scan_file}"
    if ! ssh-keyscan -T 5 -p "${port}" -t ed25519 "${host}" \
        >"${scan_file}" 2>/dev/null; then
        rm -f "${scan_file}"
        fail "could not record SSH host key for ${host}:${port}"
    fi
    if [[ "$(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "${scan_file}" | wc -l)" -ne 1 ]]; then
        rm -f "${scan_file}"
        fail "expected exactly one ED25519 host key for ${host}:${port}"
    fi
    cat "${scan_file}" >>"${known_hosts}"
    rm -f "${scan_file}"
    chmod 0600 "${known_hosts}"
}

# Authenticated SSH used by cutover/rollback probes. Keep this option vector in
# lock-step with the production verification contract.
run_remote_authenticated() {
    local target="$1" port="$2" key="$3" known_hosts="$4"
    shift 4
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "${target}" "$@"
}

open_authenticated_ssh_control() {
    local target="$1" port="$2" key="$3" known_hosts="$4" control_socket="$5"
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o ControlMaster=yes -o ControlPath="${control_socket}" \
        -o ControlPersist=600 -fN "${target}"
}

run_remote_over_control() {
    local target="$1" port="$2" key="$3" known_hosts="$4" control_socket="$5"
    shift 5
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o ControlPath="${control_socket}" \
        "${target}" "$@"
}

close_authenticated_ssh_control() {
    local target="$1" port="$2" key="$3" known_hosts="$4" control_socket="$5"
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o ControlPath="${control_socket}" -O exit "${target}" >/dev/null
}

require_authenticated_ssh_closed() {
    local target="$1" port="$2" key="$3" known_hosts="$4"
    if run_remote_authenticated "${target}" "${port}" "${key}" "${known_hosts}" \
        'true' >/dev/null 2>&1; then
        fail "authenticated SSH unexpectedly remained open on ${target}:${port}"
    fi
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

# boot_vm <tmp_dir> <image> <disk_gb> <mem_mb> <smp> <instance_id> <hostname> \
#         [user_data_file] [hostfwd ...]
# Boots a headless qemu/KVM VM with a NoCloud cloud-init seed. Requires an SSH
# keypair at <tmp_dir>/id_ed25519(.pub). When <user_data_file> is empty, a
# default user-data is generated granting that key; otherwise the file is used
# verbatim. Remaining args are hostfwd entries such as
#   hostfwd=tcp:127.0.0.1:2223-:22
# Sets the global QEMU_PID (used by the caller's cleanup trap) and writes the
# serial console to <tmp_dir>/serial.log.
boot_vm() {
    local tmp_dir="$1" image="$2" disk_gb="$3" mem_mb="$4" smp="$5"
    local instance_id="$6" hostname="$7" user_data_file="$8"
    shift 8
    local hostfwd netdev="user,id=n0"

    echo "[E2E] Preparing the cloud image..."
    if [[ "${image}" == http* ]]; then
        curl -fL --retry 3 -o "${tmp_dir}/cloud.img" "${image}"
    else
        cp "${image}" "${tmp_dir}/cloud.img"
    fi
    qemu-img create -f qcow2 -b "${tmp_dir}/cloud.img" -F qcow2 \
        "${tmp_dir}/disk.qcow2" "${disk_gb}G" >/dev/null

    echo "[E2E] Creating the cloud-init NoCloud seed..."
    mkdir -p "${tmp_dir}/seed"
    cat > "${tmp_dir}/seed/meta-data" <<SEEDEOF
instance-id: ${instance_id}
local-hostname: ${hostname}
SEEDEOF
    if [[ -n "${user_data_file}" ]]; then
        cp "${user_data_file}" "${tmp_dir}/seed/user-data"
    else
        cat > "${tmp_dir}/seed/user-data" <<SEEDEOF
#cloud-config
ssh_authorized_keys:
  - $(cat "${tmp_dir}/id_ed25519.pub")
ssh_pwauth: false
SEEDEOF
    fi
    genisoimage -quiet -output "${tmp_dir}/seed.iso" -volid cidata \
        -joliet -rock "${tmp_dir}/seed" >/dev/null

    for hostfwd in "$@"; do
        netdev+=",${hostfwd}"
    done

    echo "[E2E] Booting the VM (KVM)..."
    qemu-system-x86_64 -enable-kvm -m "${mem_mb}" -smp "${smp}" \
        -drive file="${tmp_dir}/disk.qcow2",if=virtio,format=qcow2 \
        -drive file="${tmp_dir}/seed.iso",if=virtio,format=raw \
        -netdev "${netdev}" \
        -device virtio-net-pci,netdev=n0 \
        -display none -serial file:"${tmp_dir}/serial.log" \
        -daemonize -pidfile "${tmp_dir}/qemu.pid"
    sleep 2
    if [[ ! -s "${tmp_dir}/qemu.pid" ]]; then
        echo "[FAIL] qemu did not start. Serial log:" >&2
        tail -30 "${tmp_dir}/serial.log" 2>/dev/null || true
        fail "qemu did not start"
    fi
    # shellcheck disable=SC2034  # consumed by the caller's cleanup trap
    QEMU_PID="$(cat "${tmp_dir}/qemu.pid")"
}
