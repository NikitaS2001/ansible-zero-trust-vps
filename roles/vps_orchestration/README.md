# vps_orchestration

Deploys the zero-trust VPS stack as Docker Compose services: WireGuard VPN
(wg-easy), AdGuard Home DNS sinkhole, and Caddy reverse proxy. Also installs
Docker, creates persistent volumes, and integrates UFW with Docker through a
dedicated UFW-before-Docker hook script.

## Purpose

This role turns a hardened VPS (see `vps_hardening`) into a self-hosted
zero-trust VPN gateway:

- Installs Docker Engine and Docker Compose from the official APT repository
- Creates the Docker bridge network on a fixed subnet
- Deploys wg-easy (WireGuard web UI) for VPN client management
- Deploys AdGuard Home for DNS blocking and `*.internal` hostname resolution
- Deploys Caddy as a TLS-terminating reverse proxy for internal hostnames
- Patches UFW to work correctly with Docker published ports

## Variables

| Variable | Default | Description |
|---|---|---|
| `project_root` | `/opt/zero-trust-vps` | Base directory for all service data and configs |
| `docker_network_subnet` | `172.20.0.0/24` | Subnet for the Docker bridge network |
| `adguard_container_ip` | `172.20.0.2` | Fixed IP for the AdGuard container |
| `caddy_container_ip` | `172.20.0.3` | Fixed IP for the Caddy container |
| `wg_easy_container_ip` | `172.20.0.4` | Fixed IP for the wg-easy container |
| `wg_easy_version` | `15.3.0` | wg-easy Docker image tag |
| `wg_vpn_subnet` | `10.8.0.0/24` | WireGuard client subnet |
| `wg_server_ip` | `10.8.0.1` | WireGuard server VPN IP |
| `wg_client_dns` | `172.20.0.2` | DNS server IP for WireGuard clients |
| `wg_container_port` | `51820` | WireGuard UDP port published on the host |
| `wg_internal_domain` | `wg.internal` | Internal hostname for wg-easy web UI |
| `adguard_internal_domain` | `adguard.internal` | Internal hostname for AdGuard admin UI |
| `wg_easy_bootstrap_ui_port` | `51821` | wg-easy UI port bound to localhost |
| `adguard_bootstrap_ui_port` | `3000` | AdGuard UI port bound to localhost |
| `docker_apt_distribution` | *(derived)* | Lowercase distribution name for Docker APT repo |
| `docker_apt_release` | *(derived)* | Debian/Ubuntu release codename |
| `docker_apt_arch` | *(derived)* | Architecture map to Docker arch string (amd64/arm64/armhf) |
| `docker_apt_gpg_url` | *(derived)* | GPG key URL for Docker APT repository |
| `docker_apt_repo_url` | *(derived)* | APT repository base URL |
| `docker_apt_gpg_checksum` | *(derived)* | SHA256 checksum of Docker GPG key file |
| `ufw_docker_commit` | `020a8699f95592561f254d8d4ad1bb40d401dfc7` | Git commit of `ufw-docker` hook to install |
| `ufw_docker_checksum` | *(derived)* | SHA256 checksum of `ufw-docker` script |
| `root_ca_path_on_host` | *(derived)* | Path to Caddy-generated root CA certificate |
| `fetched_certs_dir` | `fetched_certs` | Local directory where role copies certs for retrieval |
| `vault_adguard_password_hash` | `""` | bcrypt hash for AdGuard admin UI (required for AdGuard setup) |

## Tags

| Tag | Purpose |
|---|---|
| `volumes` | Create project directory structure and Docker volume mounts |
| `docker` | Install Docker Engine and Docker Compose |
| `ufw_docker` | Install UFW-before-Docker hook script |
| `adguard` | Generate AdGuard configuration and bootstrap password |
| `compose` | Deploy all Docker Compose services |

## Handlers

| Handler | Listened Events | Action |
|---|---|---|
| Restart docker | `restart docker` | Restart the Docker service |
| Reload ufw | `reload ufw` | Reload UFW firewall rules |

## Docker Compose Services

| Service | Image | Internal Port | External Port | Purpose |
|---|---|---|---|---|
| wg-easy | `ghcr.io/wg-easy/wg-easy:15.3.0` | 51821 (UI), 51820 (WireGuard UDP) | 51820/udp | WireGuard VPN with web UI |
| AdGuard Home | `adguard/adguardhome:v0.107.76` | 3000 (UI), 53 (DNS) | none | DNS sinkhole and `.internal` resolver |
| Caddy | `caddy:2.11.3` | 80, 443 | none | TLS reverse proxy for internal hostnames |

Caddy and AdGuard are not published on the public interface. They are accessed
via the Docker network or through SSH tunnels during bootstrap.

## Example Playbook

```yaml
- hosts: vps
  become: true
  roles:
    - role: vps_orchestration
      vars:
        project_root: /opt/zero-trust-vps
        docker_network_subnet: "172.20.0.0/24"
        adguard_container_ip: "172.20.0.2"
        caddy_container_ip: "172.20.0.3"
        wg_easy_container_ip: "172.20.0.4"
        wg_easy_version: "15.3.0"
        wg_container_port: 51820
        wg_internal_domain: wg.internal
        adguard_internal_domain: adguard.internal
        wg_easy_bootstrap_ui_port: 51821
        adguard_bootstrap_ui_port: 3000
        root_ca_path_on_host: "{{ project_root }}/volumes/caddy/data/caddy/pki/authorities/local/root.crt"
        fetched_certs_dir: fetched_certs
        vault_adguard_password_hash: "{{ adguard_password_hash }}"
```

## Certificate Fetching

After the role runs, the root CA certificate used for `.internal` hostnames
is copied from the Caddy container volume to `{{ fetched_certs_dir }}/<hostname>/root.crt`.
Import this certificate into your client OS or browser to trust HTTPS endpoints
on `.internal` domains.

## Security Notes

### File Permissions on Generated Configs

Config files containing secrets (e.g., AdGuardHome.yaml, wg-easy config) are
generated by Ansible templates and deployed to the host. These files should
have mode `0600` to prevent exposure of credentials:

```bash
chmod 600 /opt/zero-trust-vps/volumes/adguard/conf/AdGuardHome.yaml
chmod 600 /opt/zero-trust-vps/volumes/wg-easy/etc/wireguard/config.json
```

The role uses `ansible.builtin.template` for config generation. Ensure any
post-deployment file permission hardening is applied via:

```yaml
- name: Harden config file permissions
  ansible.builtin.file:
    path: "{{ item.path }}"
    mode: '0600'
  loop:
    - path: "{{ project_root }}/volumes/adguard/conf/AdGuardHome.yaml"
    - path: "{{ project_root }}/volumes/wg-easy/etc/wireguard/config.json"
```

### Secrets Handling in Bootstrap Mode

When running in bootstrap mode (via `bootstrap.sh`), secrets are passed
directly to `ansible-playbook` via `-e` flags, not written to disk:

```bash
ansible-playbook -i inventory/localhost.yml site.yml \
  -e "admin_password=${ADMIN_PASSWORD}" \
  -e "adguard_password=${ADGUARD_PASSWORD}" \
  -e "vault_admin_ssh_pubkey=${SSH_PUBKEY}" ...
```

This approach keeps secrets out of files and avoids accidental commit of
plaintext credentials. The `-e` variables flow through the playbook and are
used directly by roles without persisting to intermediate files.

### Check Mode Support
This role supports Ansible check mode (`--check`). Tasks are idempotent and safe to run in check mode.

## Dependencies

- `vps_hardening` (UFW must be configured before this role runs)
- Docker requires a Linux kernel with iptables support
