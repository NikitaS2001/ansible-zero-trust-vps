# Configuration

The examples in `group_vars/all/` are the starting point for remote deployment.
Role argument specifications are the executable input contract; the role
references summarize the stable surface without duplicating every internal
default.

## Secret boundary

Keep ordinary settings in `group_vars/all/vars.yml`. Keep all credentials in
whole-file encrypted vaults:

- `vault_admin_password_hash`: a random SHA-512 crypt hash;
- `vault_adguard_password_hash`: a bcrypt hash;
- `vault_wg_easy_bootstrap_secret`: the initial wg-easy password;
- `vault_admin_ssh_pubkey`: the managed administrator public key.

`vars.yml` must reference the vault values:

```yaml
admin_password_hash: "{{ vault_admin_password_hash }}"
wg_easy_bootstrap_secret: "{{ vault_wg_easy_bootstrap_secret }}"
```

Do not define `admin_password`, `wg_easy_admin_password`, or put plaintext
credentials in inventory, Compose overrides, command arguments, or issues.
wg-easy bootstrap values are first-start inputs; later UI changes are not
silently replaced by Ansible.

The public installer maintains the same logical values in its private encrypted
vault under `/etc/zero-trust-vps` and preserves them across reruns.

## Traffic policy

```yaml
wg_traffic_mode: services
```

`services` is the default and is enforced on the server. Clients can reach only
`wg_services_only_ipv4_destinations` and
`wg_services_only_ipv6_destinations`; modifying AllowedIPs on a client does not
bypass that policy.

```yaml
wg_traffic_mode: full
```

`full` provides IPv4 internet egress through the VPS and requires working IPv4
egress. IPv6 is added when the host proves IPv6 egress; otherwise generated
profiles omit `::/0`, so client IPv6 remains outside the VPN. The mode is applied
as a rollback-capable transaction. There is no `wg_enable_ipv6` input. Changing
modes requires an explicit configuration change and updated client profiles.

## Ports and identity

Review these values before the first run:

| Input | Purpose |
| --- | --- |
| `ssh_port` | Hardened SSH listener and provider firewall rule |
| `wg_port` | Public WireGuard UDP port |
| `admin_user` | Managed, sudo-capable administrator |
| `vault_admin_ssh_pubkey` | Exclusive managed SSH key by default |
| `wg_public_host` | Public address written to new client profiles |

The administrator belongs to the sudo and Docker groups. Docker access is
root-equivalent. By default, reruns remove unmanaged keys and extra groups from
that account; see the [hardening reference](../roles/vps_hardening/README.md)
before changing the exclusivity policy.

## Internal names

The default suffix is `internal`, producing `wg.internal` and
`adguard.internal`. To use the reserved home-network suffix:

```yaml
internal_domain_suffix: home.arpa
```

The derived names become `wg.home.arpa` and `adguard.home.arpa`. Explicit
`wg_internal_domain` and `adguard_internal_domain` overrides must end in the
configured suffix. Avoid `.local`, which conflicts with mDNS, and unreserved
suffixes such as `.lan` or `.home`.

## Network addresses

The Docker and WireGuard IPv4/IPv6 networks must be distinct. Static container
addresses must belong to the Docker networks, and service-only destinations
must belong to a managed Docker or VPN network. Change these values only when
they overlap an existing host or provider network.

## Package policy

The hardening role does not upgrade all packages by default. Set
`vps_hardening_apply_package_upgrade: true` only when the deployment should
apply the configured apt upgrade mode. Image and upstream installer references
are digest/checksum pinned in role defaults; update them through a reviewed code
change rather than local overrides.

Neither role manages swap or zram. A host with less than 900 MiB of RAM visible
to the OS is rejected even if it has swap; this threshold normally corresponds
to a 1 GB VPS plan after hypervisor reservations.
