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
- Deploys AdGuard Home for DNS blocking and the configured internal suffix
- Deploys Caddy as a TLS-terminating reverse proxy for internal hostnames
- Patches UFW to work correctly with Docker published ports

## Variables

| Variable | Default | Description |
|---|---|---|
| `project_root` | `/opt/zero-trust-vps` | Base directory for all service data and configs |
| `docker_network_subnet` | `10.66.0.0/24` | Subnet for the Docker bridge network |
| `adguard_container_ip` | `10.66.0.2` | Fixed IP for the AdGuard container |
| `caddy_container_ip` | `10.66.0.3` | Fixed IP for the Caddy container |
| `wg_easy_container_ip` | `10.66.0.4` | Fixed IP for the wg-easy container |
| `wg_easy_version` | `15.3.0` | wg-easy Docker image tag |
| `wg_vpn_subnet` | `10.8.0.0/24` | WireGuard client subnet |
| `wg_server_ip` | `10.8.0.1` | WireGuard server VPN IP |
| `wg_client_dns` | `10.66.0.2` | DNS server IP for WireGuard clients |
| `wg_port` | `51820` | Public WireGuard UDP port published on the host |
| `wg_container_port` | `51820` | WireGuard UDP port inside the wg-easy container |
| `wg_easy_admin_user` | `admin` | wg-easy panel username used by the automated first-start setup |
| `wg_easy_admin_password` | `""` | wg-easy panel password; enables the `INIT_*` automated first-start setup |
| `wg_public_host` | `""` | Public IP/domain WireGuard clients connect to (required when `INIT_*` is used) |
| `wg_allowed_ips` | `["10.8.0.0/24", "10.66.0.2/32", "10.66.0.3/32"]` | Default Allowed IPs for new wg-easy clients |
| `wg_enable_ipv6` | `false` | Dual-stack stack: peers get IPv6 addresses and `::/0` automatically (no IPv6 leak); requires a host with IPv6 egress, otherwise the playbook refuses |
| `wg_internal_domain` | `wg.internal` | Internal hostname for wg-easy web UI (derived from `internal_domain_suffix`, overridable) |
| `adguard_internal_domain` | `adguard.internal` | Internal hostname for AdGuard admin UI (derived from `internal_domain_suffix`, overridable) |
| `internal_domain_suffix` | `internal` | Local DNS suffix for the AdGuard `*.<suffix>` rewrite; keep `.internal` (ICANN-reserved) or `.home.arpa` |
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
| `vps_orchestration_enable_ufw_before_ufw_docker` | `false` | Enable UFW after Docker/Compose are running and before UFW-Docker is installed, used by the public installer |
| `root_ca_path_on_host` | *(derived)* | Path to Caddy-generated root CA certificate |
| `fetched_certs_dir` | `fetched_certs` | Local directory where role copies certs for retrieval |
| `vault_adguard_password_hash` | `""` | bcrypt hash for AdGuard admin UI (required for AdGuard setup) |

## Tags

| Tag | Purpose |
|---|---|
| `volumes` | Create project directory structure and Docker volume mounts |
| `docker` | Install Docker Engine and Docker Compose |
| `ufw_docker` | Install UFW-before-Docker hook script |
| `adguard` | Generate AdGuard configuration and admin password hash |
| `compose` | Deploy all Docker Compose services |
| `verify` | Verify generated CA and externally closed HTTPS port |

## Handlers

| Handler | Listened Events | Action |
|---|---|---|
| Restart docker | `restart docker` | Restart the Docker service |
| Reload ufw | `reload ufw` | Reload UFW firewall rules |

## Docker Compose Services

| Service | Image | Internal Port | External Port | Purpose |
|---|---|---|---|---|
| wg-easy | `ghcr.io/wg-easy/wg-easy:15.3.0` | 51821 (UI), 51820 (WireGuard UDP) | 51820/udp | WireGuard VPN with password-protected web UI |
| AdGuard Home | `adguard/adguardhome:v0.107.78` | 3000 (UI), 53 (DNS) | none | DNS sinkhole and `.internal` resolver |
| Caddy | `caddy:2.11.4` | 80, 443 | none | TLS reverse proxy for internal hostnames |

Caddy and AdGuard are not published on the public interface. They are accessed
via the Docker network or through SSH tunnels during initial setup.

## Example Playbook

```yaml
- hosts: vps
  become: true
  roles:
    - role: vps_orchestration
      vars:
        project_root: /opt/zero-trust-vps
        docker_network_subnet: "10.66.0.0/24"
        adguard_container_ip: "10.66.0.2"
        caddy_container_ip: "10.66.0.3"
        wg_easy_container_ip: "10.66.0.4"
        wg_easy_version: "15.3.0"
        wg_port: 51820
        wg_container_port: 51820
        wg_internal_domain: wg.internal
        adguard_internal_domain: adguard.internal
        wg_easy_bootstrap_ui_port: 51821
        adguard_bootstrap_ui_port: 3000
        root_ca_path_on_host: /opt/zero-trust-vps/volumes/caddy/data/caddy/pki/authorities/local/root.crt
        fetched_certs_dir: fetched_certs
        vault_adguard_password_hash: "$2y$..."
```

## Certificate Fetching

After the role runs, the root CA certificate used for internal hostnames is
copied from the Caddy container volume to
`fetched_certs/<inventory-host>/root.crt` by default.
Import this certificate into your client OS or browser to trust HTTPS endpoints
on the configured suffix.

## Security Notes

### File Permissions on Generated Configs

The role writes `AdGuardHome.yaml` from an Ansible template with mode `0600`,
because it contains the AdGuard admin password hash. With the default project
root, wg-easy persists its own WireGuard state under
`/opt/zero-trust-vps/volumes/wg-easy`; review that
directory after first setup if you need stricter host-level permissions.

### Configuration Lifecycle

There are two different contracts, know which one applies:

- **AdGuard is always managed by Ansible.** The role rewrites
  `volumes/adguard/conf/AdGuardHome.yaml` from a template on every run, so
  UI-side changes are overwritten on the next deployment and can recreate the
  container. Edit the template or `group_vars` instead.
- **wg-easy is bootstrap-only.** The `INIT_*` variables configure the server
  on the first container start and are ignored afterwards; changes are made
  in the wg-easy admin panel and persist in the volume. Re-running the
  playbook does not re-apply wg-easy settings. The `INIT_*` block is stripped
  from the Compose file in the same run that creates the server, so the panel
  password is not left on disk.
- **Caddy extensions are transactionally activated.** The role builds a
  private candidate from the managed file and every `Caddyfile.d` user site,
  validates the complete tree with Caddy `2.11.4`, atomically installs the
  managed file, and reloads the running process only when the tree changed.
  If reload fails, it rolls back the prior active file and reloads the
  known-good configuration; invalid candidates never replace the active file.

### Automated wg-easy Initial Setup

When `wg_easy_admin_password` and `wg_public_host` are set, the role renders
wg-easy's `INIT_*` environment variables (username, password, host, port, DNS,
default Allowed IPs) into the Compose file. wg-easy consumes them during the
first container start and ignores them afterwards, so the panel is
password-protected without the interactive setup wizard. The `INIT_*` block is
gated on the wg-easy v15 SQLite database
(`/opt/zero-trust-vps/volumes/wg-easy/wg-easy.db` by default), which is the authoritative
initialized-state sentinel (the old `wg0.conf` sentinel did not match the v15
lifecycle where the DB is the source of truth). On the first deploy the role
re-renders the Compose file without the block **and** runs a second
`docker compose up --force-recreate` so the panel password is removed both from
the file and from the running container's `Config.Env`. Existing deployments
still carrying `INIT_PASSWORD` in the container environment are healed on the
next playbook run (the role detects it via `docker inspect` and recreates the
container).

### CVE-2026-63089 route boundary

The stable `ghcr.io/wg-easy/wg-easy:15.3.0` image remains affected and is not
claimed patched. Caddy returns HTTP `404` plus
`X-Zero-Trust-Policy: cve-2026-63089` for `/cnf`, `/cnf/`, and `/cnf/*` at the
wg-easy site. Normal UI and API routes continue to work without the policy
header. Caddy is container-network-only and is never published on host 443.

### Suffix-only configuration

Setting only `internal_domain_suffix: home.arpa` derives the concrete
`wg.home.arpa` and `adguard.home.arpa` endpoints. The role renders and tests
those resolved names; user-facing examples must not contain unresolved Jinja
domain expressions.

### Recovery contract

Backups are encrypted by default and require a public `AGE_KEY` recipient plus
the `age` executable before containers stop. `scripts/backup.sh` publishes a
mode-`0600` `.age` file; plaintext requires `--allow-plaintext`. Restore first
validates and stages the full archive, then atomically activates it, recomputes
Compose inputs, and waits for readiness. Startup failure rolls the disk state
back and restarts the prior stack.

### Secrets Handling in Installer Mode

When running through the public installer, secrets are written to a temporary
extra-vars file with mode `0600` and passed to Ansible by path:

```bash
ansible-pull -U "${REPO_URL}" -C "${RELEASE_REF}" --extra-vars "@/path/to/extra-vars.yml"
```

The installer removes that file after success or failure. Password hashes are
generated by Ansible on the controller side with `no_log: true`, so plaintext
passwords are not passed through target process arguments.

### Check Mode Support
Check mode is **not** reliably supported: `command`-based preconditions report
synthetic success in `--check` and template gates depend on runtime state. Run
the role normally; do not rely on `--check` for change prediction.

## Dependencies

- `vps_hardening` (UFW host rules must be configured before this role runs)
- Docker requires a Linux kernel with iptables support
