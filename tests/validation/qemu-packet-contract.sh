#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
readonly CLIENT="${ROOT_DIR}/tests/e2e/client-in-guest.sh"
readonly COMMON="${ROOT_DIR}/tests/e2e/common.sh"
readonly QEMU="${ROOT_DIR}/tests/e2e/qemu-install.sh"

grep -Fq "AllowedIPs = 0.0.0.0/0, ::/0" "${CLIENT}"
grep -Fq -- '--interface zt-e2e' "${CLIENT}"
grep -Fq 'https://1.1.1.1/cdn-cgi/trace' "${CLIENT}"
grep -Fq 'https://[2606:4700:4700::1111]/cdn-cgi/trace' "${CLIENT}"
grep -Fq 'public egress escaped services_only through WireGuard' "${CLIENT}"
grep -Fq 'public egress failed through full_tunnel' "${CLIENT}"
grep -Fq 'IPv6 direct-egress control is required for full_tunnel' "${CLIENT}"
grep -Fq 'IPv6 public-egress packet probe: test host has no direct IPv6' "${CLIENT}"
grep -Fq 'docker exec wg-easy wg show wg0 peers' "${CLIENT}"
grep -Fq "tr -d '\\r' | wg pubkey" "${CLIENT}"
grep -Fq 'ping -I zt-e2e' "${CLIENT}"
grep -Fq 'WireGuard client could not establish a handshake' "${CLIENT}"
grep -Fq 'ip6tables -C FORWARD -i wg0 -j WG_CLIENTS' "${COMMON}"
grep -Fq "WG_TRAFFIC_MODE='\${WG_TRAFFIC_MODE}'" "${QEMU}"

printf 'qemu-packet-contract: strict IPv4 and environment-qualified IPv6 packet assertions wired PASS\n'
