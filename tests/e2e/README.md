# E2E Testing of the Public Installer

This directory contains end-to-end tests for the public `curl | sudo bash`
installer. Three targets are supported:

| Script | Target | Purpose |
|---|---|---|
| `qemu-install.sh` | Plain qemu/KVM VM | Fast iteration when only qemu + KVM are available |
| `run-public-install.sh` | Real VPS | Final verification of a release tag |
| `client-test.sh` | Any of the above + this machine | Real WireGuard client handshake over the VPN |

## Fast iteration: qemu/KVM

Needs `qemu-system-x86_64`, `qemu-img`, `genisoimage`, `curl` and KVM
support (`/dev/kvm`). No libvirt daemon required.

```bash
tests/e2e/qemu-install.sh --reboot-test
# Ubuntu 24.04 is the default image; use a Debian image with:
QEMU_IMAGE=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 QEMU_USER=debian tests/e2e/qemu-install.sh
```

The VM is booted headless with a cloud-init NoCloud seed, the repository is
copied in, and the installer runs non-interactively exactly like on a real
host. `--client-test` is skipped automatically when wireguard-tools are
missing or the host already routes `10.8.0.0/24`.

## Prerequisites

### Real VPS

- A **fresh, disposable** Debian/Ubuntu VPS with root SSH access.
- Provider firewall must allow the current SSH port, the hardened SSH port
  (default `2222`), and the WireGuard UDP port (default `51820`).
- The VPS kernel must support TUN and WireGuard (see the playbook preflight).

### Client test

- `curl`, `jq`, `wireguard-tools` (`wg`/`wg-quick`), `/dev/net/tun` on the
  machine running the test, and root for `wg-quick up`.

## Final check: real VPS (release candidate)

```bash
VPS_IP=203.0.113.10 \
VPS_SSH_KEY=~/.ssh/id_ed25519 \
VPS_SSH_PORT=22 \
INSTALL_REF=v1.0.0 \
tests/e2e/run-public-install.sh --reboot-test
```

The remote script executes the exact documented command on the VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/NikitaS2001/ansible-zero-trust-vps/${INSTALL_REF}/install.sh | sudo bash
```

with the non-interactive `ZERO_TRUST_*` variables, then runs the same
verification suite over the hardened SSH port.

## Client handshake test

After an install, run from a machine with TUN and wireguard-tools:

```bash
TARGET=sysadmin@203.0.113.10 \
ADMIN_SSH_PORT=2222 \
SSH_KEY=~/.ssh/id_ed25519 \
WG_PASSWORD='<panel password from the install>' \
WG_ENDPOINT=203.0.113.10:51820 \
tests/e2e/client-test.sh
```

It creates a client through the wg-easy API over an SSH tunnel, brings up
`wg-quick`, and verifies that AdGuard (`10.66.0.2`) and the internal HTTPS
endpoints are reachable through the VPN.

## CI

`.github/workflows/e2e-public-install.yml` runs `run-public-install.sh` against
a VPS on demand (`workflow_dispatch`). Configure the repository secrets:

- `E2E_VPS_IP` — public IP of the test VPS.
- `E2E_VPS_SSH_PORT` — root SSH port (usually `22`).
- `E2E_VPS_SSH_KEY` — **base64-encoded** PEM private key for root access.

```bash
base64 -w0 ~/.ssh/id_ed25519   # put the output into the secret
```

Use a dedicated key; the test VPS is disposable.
