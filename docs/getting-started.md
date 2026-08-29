# Getting started

Choose one installation path. The public installer is the recommended path for
one fresh VPS. Remote Ansible is intended for an existing controller workflow.

## Before installation

Use a fresh Debian 12 or Ubuntu 24.04 amd64 VPS on a 1 GB or larger plan, with
at least 900 MiB of RAM visible to the OS. Confirm `/dev/net/tun`, WireGuard,
iptables/NAT, outbound network access, and a recovery console. Existing swap is
diagnostic-only and is never changed.

> [!WARNING]
> Open the planned SSH and WireGuard ports in the provider firewall before
> deployment. Keep the original SSH session open and provider console access
> available until login on the hardened port succeeds.

## Verified published installer

After the maintainer publishes the `v1.3.0` tag and GitHub release, install and
authenticate [GitHub CLI](https://cli.github.com/) on the VPS, then follow the
repository's single [Verified release installation](../README.md#verified-release-installation-after-publication).
It downloads the exact release assets, verifies GitHub's attestation and the
published checksum, and runs only the verified local installer bytes.

The installer verifies the signed release tag again before using its detached
commit. It asks for:

- `services_only` or `full_tunnel` traffic policy;
- hardened SSH and WireGuard ports;
- administrator name and password;
- AdGuard and wg-easy passwords;
- internal domain suffix and optional names;
- public WireGuard endpoint;
- administrator SSH public key.

Defaults are shown at each prompt. `services_only` is the default. Choose
`full_tunnel` only on a host with working IPv4 and IPv6 egress.

The checkout and virtual environment remain under
`/opt/zero-trust-vps-installer`. Deployment values are persisted under
`/etc/zero-trust-vps` in a root-owned, encrypted Ansible Vault. A rerun reuses
all persisted inputs and rejects implicit configuration or credential changes.
Run the same verified local `install.sh` bytes again only to converge or upgrade
the same configuration. Configuration changes and secret rotation are explicit
operator operations; use one management path and do not mix controller-managed
state with later public-installer reruns.

## Remote Ansible deployment

On the controller, clone a tagged release and create local files from the
examples:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all/vars.yml.example group_vars/all/vars.yml
cp group_vars/all/vault_services.yml.example \
  group_vars/all/vault_services.yml
cp group_vars/all/vault_ssh.yml.example group_vars/all/vault_ssh.yml
chmod 0600 group_vars/all/vault_services.yml \
  group_vars/all/vault_ssh.yml
```

Edit the inventory and variables. Replace every vault placeholder, including
`vault_admin_password_hash`, `vault_adguard_password_hash`,
`vault_wg_easy_bootstrap_secret`, and `vault_admin_ssh_pubkey`. The wg-easy
secret must be at least 12 characters. Set `wg_public_host` and review
`wg_traffic_mode`.

Bootstrap the pinned controller toolchain, then encrypt both vault files before
running the playbook:

```bash
./scripts/bootstrap.sh
ansible-vault encrypt \
  group_vars/all/vault_services.yml \
  group_vars/all/vault_ssh.yml
ansible-playbook --ask-vault-pass --syntax-check site.yml
ansible-playbook --ask-vault-pass site.yml -u root
```

After the first run, change the inventory connection to the managed account and
hardened port before rerunning:

```yaml
ansible_user: sysadmin
ansible_port: 2222
```

The service vault must remain a regular, non-symlink, whole-file encrypted
Ansible Vault with mode `0600`. Plaintext `wg_easy_admin_password` and
`admin_password` variables are rejected.

## First WireGuard client

Forward the wg-easy UI through SSH:

```bash
ssh -p <ssh_port> -L 51821:127.0.0.1:51821 \
  <admin_user>@<vps-address>
```

Open `http://127.0.0.1:51821`, sign in, create a client, and import its profile.
Connect the client before opening the internal sites. In `services_only` mode,
the server enforces access only to the managed VPN and service destinations;
editing the client profile cannot turn it into a full tunnel.

The internal sites default to `https://wg.internal` and
`https://adguard.internal`. Trust the Caddy root certificate fetched by remote
Ansible under `fetched_certs/<inventory-host>/root.crt`. A public installation
keeps the checkout's fetched copy under
`/opt/zero-trust-vps-installer/repo/fetched_certs/localhost/root.crt`.

AdGuard's bootstrap UI is available through a separate tunnel when needed:

```bash
ssh -p <ssh_port> -L 3000:127.0.0.1:3000 \
  <admin_user>@<vps-address>
```

Continue with [Configuration](configuration.md) or
[Operations](operations.md).
