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
| `admin_group` | `sudo` | Sudo-capable group for `admin_user` |
| `admin_shell` | `/bin/bash` | Login shell for `admin_user` |
| `admin_password_hash` | `""` | Precomputed admin password hash (optional; key auth is primary) |
| `vault_admin_ssh_pubkey` | `""` | SSH public key content for `admin_user` (required for key auth) |
| `ssh_service_name` | `ssh` | Name of the SSH service to restart |
| `ssh_socket_name` | `ssh.socket` | Name of the systemd SSH socket unit when socket activation is present |
| `ssh_allow_tcp_forwarding` | `"yes"` | Allow SSH TCP forwarding (`"yes"` or `"no"`) |
| `vps_hardening_manage_ssh_socket` | `true` | Disable SSH socket activation so `sshd_config` owns the hardened port |
| `wg_easy_bootstrap_ui_port` | `51821` | wg-easy UI port bound to localhost (for SSH tunnel access) |
| `adguard_bootstrap_ui_port` | `3000` | AdGuard UI port bound to localhost (for SSH tunnel access) |
| `fail2ban_ignore_ips` | `["127.0.0.1/8"]` | IPs ignored by fail2ban |
| `fail2ban_bantime` | `3600` | fail2ban ban duration in seconds |
| `fail2ban_findtime` | `600` | fail2ban find-time window in seconds |
| `fail2ban_maxretry` | `5` | fail2ban retries before a ban |
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
        admin_shell: /bin/bash
        vault_admin_ssh_pubkey: "ssh-ed25519 AAAA... operator@example"
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

## Firewall and release boundary

UFW is managed by this role, but the provider firewall remains the operator's
responsibility. Allow the current SSH port, hardened SSH port, and WireGuard
UDP port at the provider before deployment; keep the existing authenticated
session until a new key-authenticated login succeeds. The SSH tasks validate
the candidate daemon configuration and restore the prior configuration when
the new login cannot be proven.

Local syntax checks and QEMU coverage do not prove provider routing or live
access. Release readiness therefore requires a fresh disposable VPS and an
external client; missing provider access or live secrets is a blocking result,
not a skipped pass.

### Check Mode Support
Check mode is **not** reliably supported: several tasks use `command`/template
preconditions that report synthetic success in `--check`. Run the role normally
on a fresh host; do not rely on `--check` for change prediction.

## Dependencies

None.
