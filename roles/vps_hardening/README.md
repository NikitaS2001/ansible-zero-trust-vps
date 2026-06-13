# vps_hardening

Hardens a fresh VPS by installing and configuring UFW firewall, fail2ban
brute-force protection, SSH key authentication, a non-root admin user, and
kernel-level network hardening via sysctl.

## Purpose

This role brings a Debian/Ubuntu VPS to a secure baseline:

- Installs and enables UFW with default-deny incoming policy
- Creates a non-root sudo user with SSH public-key authentication
- Hardens the SSH daemon (non-standard port, key auth only, forwarding limited
  to the configured localhost UI ports)
- Applies kernel network sysctl settings (IP forwarding, rpfilter, etc.)
- Installs and configures fail2ban to block brute-force SSH attackers

## Variables

| Variable | Default | Description |
|---|---|---|
| `ssh_port` | `2222` | Hardened SSH listening port |
| `wg_port` | `51820` | WireGuard UDP port (opened in UFW) |
| `admin_user` | `sysadmin` | Name of the non-root admin account |
| `admin_group` | `sudo` | Primary group for `admin_user` |
| `admin_password_hash` | `""` | Precomputed admin password hash (optional; key auth is primary) |
| `vault_admin_ssh_pubkey` | `""` | SSH public key content for `admin_user` (required for key auth) |
| `ssh_service_name` | `ssh` | Name of the SSH service to restart |
| `ssh_socket_name` | `ssh.socket` | Name of the systemd SSH socket unit when socket activation is present |
| `ssh_allow_tcp_forwarding` | `"yes"` | Allow SSH TCP forwarding (`"yes"` or `"no"`) |
| `vps_hardening_manage_ssh_socket` | `true` | Disable SSH socket activation so `sshd_config` owns the hardened port |
| `wg_easy_bootstrap_ui_port` | `51821` | wg-easy UI port bound to localhost (for SSH tunnel access) |
| `adguard_bootstrap_ui_port` | `3000` | AdGuard UI port bound to localhost (for SSH tunnel access) |
| `fail2ban_ignore_ips` | `["127.0.0.1/8"]` | IPs ignored by fail2ban |
| `vps_hardening_apply_package_upgrade` | `false` | Whether to upgrade system packages |
| `vps_hardening_package_upgrade_mode` | `"safe"` | Upgrade mode: `"safe"` (dist-upgrade --no-install-recommends) or `"full"` |
| `vps_hardening_enable_ufw_on_local_connection` | `false` | Allow UFW enablement when Ansible connects locally, used by the public installer on the VPS |

## Tags

| Tag | Purpose |
|---|---|
| `preflight` | Validate supported target environment |
| `packages` | Install and upgrade system packages |
| `user` | Create admin user and configure sudo |
| `ssh` | Harden SSH daemon configuration |
| `sysctl` | Apply kernel network hardening sysctl values |
| `ufw` | Install and configure UFW firewall |
| `fail2ban` | Install and configure fail2ban |

## Handlers

| Handler | Listened Events | Action |
|---|---|---|
| Restart sshd | `restart sshd` | Restart the SSH service |
| Reload sysctl | `reload sysctl` | Reapply sysctl settings system-wide |
| Restart fail2ban | `restart fail2ban` | Restart fail2ban daemon |

## Example Playbook

```yaml
- hosts: vps
  become: true
  roles:
    - role: vps_hardening
      vars:
        ssh_port: 2222
        wg_port: 51820
        admin_user: sysadmin
        admin_group: sudo
        vault_admin_ssh_pubkey: "{{ lookup('file', '~/.ssh/id_ed25519.pub') }}"
        ssh_allow_tcp_forwarding: "yes"
        fail2ban_ignore_ips:
          - "127.0.0.1/8"
        vps_hardening_apply_package_upgrade: true
        vps_hardening_package_upgrade_mode: safe
```

## First Setup Access

After this role runs, access the wg-easy setup wizard through an SSH tunnel:

```sh
ssh -p 2222 -L 51821:127.0.0.1:51821 sysadmin@<vps-ip>
# Open http://127.0.0.1:51821 in your browser
```

AdGuard admin UI (once `vps_orchestration` has also run):

```sh
ssh -p 2222 -L 3000:127.0.0.1:3000 sysadmin@<vps-ip>
# Open http://127.0.0.1:3000 in your browser
```

### Check Mode Support
This role supports Ansible check mode (`--check`). Tasks are idempotent and safe to run in check mode.

## Dependencies

None.
