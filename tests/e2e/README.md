# E2E Testing of the Public Installer

This directory contains end-to-end tests for the public `curl | sudo bash`
installer. Two targets are supported:

| Script | Target | Purpose |
|---|---|---|
| `vagrant-install.sh` | Disposable Vagrant VM (libvirt/VirtualBox) | Fast iteration during development |
| `run-public-install.sh` | Real VPS | Final verification of a release tag |
| `client-test.sh` | Any of the above + this machine | Real WireGuard client handshake over the VPN |

## Prerequisites

### Vagrant (libvirt)

```bash
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients rsync vagrant
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"
# re-login, then install the provider
vagrant plugin install vagrant-libvirt
```

`vagrant-libvirt` needs `rsync` on both the host and the guest. The base
box (`ubuntu/noble64` or `debian/bookworm64`) is downloaded on the first run.

### Real VPS

- A **fresh, disposable** Debian/Ubuntu VPS with root SSH access.
- Provider firewall must allow the current SSH port, the hardened SSH port
  (default `2222`), and the WireGuard UDP port (default `51820`).
- The VPS kernel must support TUN and WireGuard (see the playbook preflight).

### Client test

- `curl`, `jq`, `wireguard-tools` (`wg`/`wg-quick`), `/dev/net/tun` on the
  machine running the test, and root for `wg-quick up`.

## Fast iteration: Vagrant VM

```bash
# Ubuntu 24.04
VAGRANT_BOX=ubuntu/noble64 tests/e2e/vagrant-install.sh

# Debian 12, with a reboot survival test and a WireGuard client test
VAGRANT_BOX=debian/bookworm64 tests/e2e/vagrant-install.sh --reboot-test --client-test
```

The installer runs non-interactively with `ZERO_TRUST_NONINTERACTIVE=1` and
clones the repository from `/vagrant` at the current branch (override with
`INSTALL_REF`). After the install, the script verifies SSH on the hardened
port, UFW state, containers, the WireGuard interface, wg-easy auth and the
AdGuard UI, then optionally reboots the VM and re-verifies.

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

After either install, run from a machine with TUN and wireguard-tools:

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
