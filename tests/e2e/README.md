# E2E Testing of the Public Installer

This directory contains end-to-end tests for the public `curl | sudo bash`
installer. Three targets are supported:

| Script | Target | Purpose |
|---|---|---|
| `qemu-install.sh` | Plain qemu/KVM VM | Public installer (`curl \| sudo bash`) — fast local iteration |
| `qemu-remote-install.sh` | Plain qemu/KVM VM | Remote deployment mode (controller → VM via SSH + vault) |
| `client-in-guest.sh` | Inside the deployed host | In-guest WireGuard handshake + DNS + internal HTTPS (used by the other tests) |

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
host.

- `--client-test` installs `wireguard-tools` inside the guest and runs a real
  WireGuard client handshake there (create client via the wg-easy API, bring
  up `wg-quick`, verify AdGuard DNS and the `.internal` HTTPS endpoints with
  the trusted root CA). This avoids touching the host network.
- `--idempotency-test` re-runs the installer on the same VM and re-verifies
  the stack, checking that a second run completes cleanly.
- Failure-mode coverage uses `--bootstrap-timeout-test`,
  `--stopped-container-test`, and `--invalid-caddy-test`. Each case must fail
  at the intended boundary, preserve recoverable state, and clean up.

## Remote deployment mode (controller -> VM)

`qemu-remote-install.sh` boots a VM as a stand-in VPS and deploys with the
remote mode documented in the README: inventory + `group_vars` + encrypted
vault files and `ansible-playbook` over SSH from this host (the controller).
It covers the code paths the public installer does not: SSH-based connection,
UFW enablement during hardening, vault decryption and the remote-only verify
tasks (SSH reachable on the new port, external 443 closed).
Use `--ssh-rollback-test --ufw-backend-failure-test` for the remote negative
cases; both must retain the prior authenticated SSH path.

## Release readiness matrix

Merge readiness requires disposable local public-QEMU coverage, disposable
remote-QEMU coverage, the named negative cases, and the encrypted
backup/restore drill. This matrix proves software merge readiness only.
GitHub Actions stores no VPS credential, and live external host availability
is out of scope for merge readiness.

The provider firewall remains the operator's responsibility. QEMU does not
prove provider-firewall behavior, routing, or a provider's host lifecycle;
verify those separately when operating a real deployment.

## Client test

`qemu-install.sh --client-test` runs `client-in-guest.sh` inside the deployed
guest. It creates a client through the wg-easy API, brings up `wg-quick`, and
verifies AdGuard (`10.66.0.2`) and the internal HTTPS endpoints with the trusted
root CA. No TUN device is needed on the machine driving the test.
