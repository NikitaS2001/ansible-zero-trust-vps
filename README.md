# Ansible Zero-Trust VPS

Ansible playbooks for a small zero-trust VPS stack with WireGuard, wg-easy,
AdGuard Home, Caddy, UFW, fail2ban, and hardened SSH.

## Stack Images

| Service | Image |
| --- | --- |
| wg-easy | `ghcr.io/wg-easy/wg-easy:15` |
| AdGuard Home | `adguard/adguardhome:v0.107.76` |
| Caddy | `caddy:2.11.3` |

## Security Notes

Real Vault files are local machine state and are ignored by git. Create them
from the examples, replace placeholders, then encrypt them with Ansible Vault:

```sh
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all/vars.yml.example group_vars/all/vars.yml
cp group_vars/all/vault_services.yml.example group_vars/all/vault_services.yml
cp group_vars/all/vault_ssh.yml.example group_vars/all/vault_ssh.yml
ansible-vault encrypt group_vars/all/vault_services.yml group_vars/all/vault_ssh.yml
```

Keep `.vault_password` out of git and restrict it to the local user.

wg-easy v15 is initialized through its first-run setup wizard. The admin
username, admin password, host, port, and DNS values are entered in the web UI
over an SSH tunnel during bootstrap, so the repository does not store a wg-easy
admin password.

AdGuard Home stores the admin password as a bcrypt hash. Generate only the hash
value, without a `username:` prefix:

```sh
htpasswd -bnBC 10 "" 'replace-with-password' | cut -d: -f2
```

IPv6 is disabled for wg-easy with `DISABLE_IPV6=true` and the container sysctl
`net.ipv6.conf.all.disable_ipv6=1`. This avoids wg-easy v15 startup issues on
VPS providers that do not provide working IPv6.

Caddy is not published on the public VPS interface. It has a fixed Docker
network IP (`172.20.0.3`) and serves the internal hostnames through the VPN
path. The public interface should expose SSH and WireGuard UDP only.

wg-easy and AdGuard admin UIs are bound to `127.0.0.1` on the VPS for
bootstrap access through SSH local forwarding. They are not published on the
public VPS interface.

wg-easy is licensed as AGPL-3.0-only. Treat it as an AGPL dependency when
redistributing or modifying the deployed stack.

## Usage

Replace placeholder inventory values, create encrypted Vault files from the
examples, then run:

```sh
ansible-playbook --vault-password-file .vault_password --syntax-check site.yml
ansible-playbook --vault-password-file .vault_password site.yml -u root
```

Optional local quality gates before committing:

```sh
ansible-lint
yamllint .
gitleaks detect --source . --no-git
```

Install required Ansible collections before local linting or deployment:

```sh
ansible-galaxy collection install -r requirements.yml
```

Before the first real run, verify these local-only files exist and are not
committed:

```sh
test -f .vault_password
test -f inventory/hosts.yml
test -f group_vars/all/vars.yml
test -f group_vars/all/vault_services.yml
test -f group_vars/all/vault_ssh.yml
git status --short --ignored
```

Trust the VPS SSH host key before running Ansible for the first time:

```sh
ssh root@<ansible_host>
```

Confirm the host key fingerprint out of band when possible. This keeps Ansible
host key checking enabled during bootstrap.

Only commit the Ansible code, README, `.gitignore`, `ansible.cfg`, `site.yml`,
and `*.example` files under `inventory/` and `group_vars/all/`. Do not commit
`.vault_password`, real `inventory/hosts.yml`, real `group_vars/all/vars.yml`,
real `group_vars/all/vault_services.yml`, real `group_vars/all/vault_ssh.yml`,
`fetched_certs/`, `.sisyphus/`, `.agents/`, or generated `volumes/`.

## User Configuration

Set these values before running against a real VPS:

| File | Variable | Purpose |
| --- | --- | --- |
| `inventory/hosts.yml` | `ansible_host` | Public VPS IP or DNS name |
| `group_vars/all/vars.yml` | `ssh_port` | Hardened SSH port after bootstrap |
| `group_vars/all/vars.yml` | `wg_port` | Public WireGuard UDP port |
| `group_vars/all/vars.yml` | `wg_container_port` | Internal wg-easy WireGuard UDP port, normally `51820` |
| `group_vars/all/vars.yml` | `admin_user` | Non-root SSH admin user created by Ansible |
| `group_vars/all/vars.yml` | `wg_internal_domain` | Internal wg-easy hostname |
| `group_vars/all/vars.yml` | `adguard_internal_domain` | Internal AdGuard hostname |
| `group_vars/all/vars.yml` | `docker_network_subnet` | Private Docker subnet for services |
| `group_vars/all/vars.yml` | `adguard_container_ip` | Fixed AdGuard Docker IP |
| `group_vars/all/vars.yml` | `caddy_container_ip` | Fixed Caddy Docker IP |
| `group_vars/all/vars.yml` | `wg_easy_container_ip` | Fixed wg-easy Docker IP |
| `group_vars/all/vars.yml` | `docker_apt_distribution` | Docker apt repo family, usually `ubuntu` or `debian` |
| `group_vars/all/vars.yml` | `docker_apt_arch` | Docker apt repo architecture, mapped from `ansible_architecture` by default |
| `group_vars/all/vars.yml` | `vps_hardening_apply_package_upgrade` | Opt-in package upgrade switch, default `false` |
| `group_vars/all/vars.yml` | `fail2ban_ignore_ips` | IP/CIDR list excluded from fail2ban bans |
| `group_vars/all/vault_services.yml` | `vault_adguard_password_hash` | AdGuard admin bcrypt password hash |
| `group_vars/all/vault_ssh.yml` | `vault_admin_ssh_pubkey` | SSH public key for `admin_user` |

`admin_user` receives passwordless sudo and membership in the `docker` group.
Both are root-equivalent privileges. This is intentional so Ansible can switch
away from root after SSH hardening and still manage Docker, files under
`project_root`, UFW, and services.

Keep `wg_client_dns` equal to `adguard_container_ip` unless you intentionally
move DNS elsewhere. Keep `adguard_container_ip`, `caddy_container_ip`, and
`wg_easy_container_ip` inside `docker_network_subnet` and outside any other
network used by the VPS.

Package upgrades are opt-in. The default playbook updates apt metadata and
installs required packages without running a full distribution upgrade; enable
`vps_hardening_apply_package_upgrade` only during a planned maintenance window.

Do not add the WireGuard client subnet to `fail2ban_ignore_ips` unless you
accept that compromised VPN clients can bypass SSH brute-force lockouts.

The user may change ports, domains, usernames, image tags, subnets, and fixed
container IPs. If the Docker subnet or fixed IPs change, also use matching
values in the wg-easy setup wizard and client Allowed IPs.

## First Client Bootstrap

wg-easy creates the initial admin account through the first-run setup wizard.
To complete setup and create the first WireGuard client, open an SSH tunnel to
the VPS after the playbook finishes:

```sh
ssh -p <ssh_port> -L 51821:127.0.0.1:51821 <admin_user>@<ansible_host>
```

Then open `http://127.0.0.1:51821`, complete the wg-easy setup wizard, and use
these values when prompted:

| Field | Value |
| --- | --- |
| Host | The VPS public IP or DNS name from `ansible_host` |
| Port | The value of `wg_port` |
| DNS | The value of `wg_client_dns` |

Keep `wg_container_port` at `51820` unless the wg-easy image changes its
internal WireGuard port. `wg_port` is the public VPS UDP port exposed to
clients.

In wg-easy, set client Allowed IPs so the Docker service subnet is routed
through the tunnel. For this repository, include:

```text
<wg_vpn_subnet>, <docker_network_subnet>
```

Create the first client in wg-easy and connect it to WireGuard. AdGuard rewrites
`*.internal` to Caddy's Docker IP (`caddy_container_ip`); after the client is
connected, use the internal HTTPS endpoints:

```text
https://wg.internal
https://adguard.internal
```

AdGuard can also be reached during bootstrap with:

```sh
ssh -p <ssh_port> -L 3000:127.0.0.1:3000 <admin_user>@<ansible_host>
```

The playbook fetches the Caddy local root certificate to
`fetched_certs/<inventory-host>/root.crt`. Import that certificate into the
client OS or browser to trust the `.internal` HTTPS endpoints.

## Documentation Alignment

This repository follows the wg-easy v15 first-run wizard flow instead of
unattended `INIT_*` setup. `INSECURE=true` is set because both SSH bootstrap
tunnels and Caddy proxy to the wg-easy UI over HTTP; TLS is provided by the SSH
tunnel during bootstrap and by Caddy on the internal `.internal` endpoints.
wg-easy documentation requires UDP `51820` for WireGuard, which is the only
container port published on the public interface by this project.

AdGuard Home is configured with the current `http.address` key for
`v0.107.76`, and the admin password value must be a bcrypt hash.
