# Ansible Zero-Trust VPS

[![CI](https://github.com/NikitaS2001/ansible-zero-trust-vps/actions/workflows/ci.yml/badge.svg)](https://github.com/NikitaS2001/ansible-zero-trust-vps/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/NikitaS2001/ansible-zero-trust-vps)](https://github.com/NikitaS2001/ansible-zero-trust-vps/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Deploy a private WireGuard entry point, filtered DNS, and internal HTTPS on a
single VPS with Ansible.

The project is designed for an operator who wants one understandable path from
a fresh server to a small self-hosted network. It is a personal Open Source
project, maintained on a best-effort basis without a support SLA or public
roadmap.

## What it deploys

| Component | Purpose | Exposure |
| --- | --- | --- |
| wg-easy | WireGuard server and client management | WireGuard UDP; UI on localhost and VPN |
| AdGuard Home | DNS filtering and internal names | Admin UI on localhost and VPN |
| Caddy | TLS for internal services | VPN only; host TCP/443 stays closed |

The host is hardened with key-only SSH, UFW, Fail2Ban, a non-root administrator,
and conservative kernel settings. Containers run on a private Docker network.

The default `services_only` mode lets VPN clients reach only the managed VPN
and service networks. `full_tunnel` is an explicit dual-stack mode and is
refused unless the host proves both IPv4 and IPv6 egress.

This is not a general-purpose hosting panel, multi-node VPN, cloud provisioning
tool, or high-availability platform.

## Requirements

- A fresh Debian 12 or Ubuntu 24.04 VPS on amd64.
- A 1 GB VPS plan with at least 900 MiB of RAM visible to the OS.
- Root access for the first installation and an interactive SSH terminal.
- `/dev/net/tun`, WireGuard, Docker-compatible iptables/NAT, and outbound
  access to the required package and image registries.
- Provider-console or rescue access, plus provider firewall rules for the old
  SSH port, new SSH port, and WireGuard UDP port.

Existing swap is reported for diagnostics only. The project never creates,
removes, enables, disables, or tunes swap or zram.

> [!WARNING]
> Installation changes SSH and UFW. Allow the new SSH port in the provider
> firewall first, keep the original authenticated session open, and confirm a
> new key-authenticated login before disconnecting. Keep provider console or
> rescue access available.

## Verified release installation

Install [GitHub CLI](https://cli.github.com/) on the VPS and authenticate it so
GitHub can verify the release attestation. Run these commands from a directory
that does not already contain the downloaded files:

<!-- ssot:verified-quickstart:start -->

```bash
mkdir zero-trust-vps-install
cd zero-trust-vps-install
gh release download v1.3.0 \
  --repo NikitaS2001/ansible-zero-trust-vps \
  --pattern install.sh \
  --pattern install.sh.sha256
gh attestation verify install.sh \
  --repo NikitaS2001/ansible-zero-trust-vps \
  --signer-workflow \
    NikitaS2001/ansible-zero-trust-vps/.github/workflows/release.yml \
  --source-ref refs/tags/v1.3.0
sha256sum --check install.sh.sha256
sudo bash ./install.sh
```

<!-- ssot:verified-quickstart:end -->

The interactive installer asks for the new SSH and WireGuard settings, three
administrator secrets, the WireGuard endpoint, internal names, and the SSH
public key. It encrypts persistent deployment inputs in an owner-only Ansible
Vault; plaintext credentials are not stored in Compose or normal variables.

For a controller-driven deployment, follow the
[remote Ansible path](docs/getting-started.md#remote-ansible-deployment).

## Connect the first client

Forward the localhost-only wg-easy UI after installation:

```bash
ssh -p <ssh_port> -L 51821:127.0.0.1:51821 \
  <admin_user>@<vps-address>
```

Open `http://127.0.0.1:51821`, sign in, create a client, and import its profile
into WireGuard. Then connect the VPN and open `https://wg.internal` or
`https://adguard.internal`. The complete sequence, including trusting the
internal CA, is in [Getting started](docs/getting-started.md).

## Documentation

- [Documentation map](docs/README.md)
- [Getting started](docs/getting-started.md)
- [Configuration](docs/configuration.md)
- [Operations and recovery](docs/operations.md)
- [Security model](docs/security.md)
- [Adding an internal service](docs/extensions.md)
- [Release process](docs/releasing.md)

The role references list stable inputs and tags:
[hardening](roles/vps_hardening/README.md) and
[orchestration](roles/vps_orchestration/README.md).

For local development, use the two repository entry points documented in
[CONTRIBUTING.md](CONTRIBUTING.md): `./scripts/bootstrap.sh` prepares the pinned
toolchain and `./scripts/check.sh` runs the fast project contracts.

## Contributing and security

Small fixes that preserve the minimal design are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities through the private
channel described in [SECURITY.md](SECURITY.md), never through a public issue.

## License

[MIT](LICENSE)
