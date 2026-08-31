# Repository Guidelines

## Project Overview

Ansible project that provisions a self-hosted zero-trust VPS: hardened SSH/UFW/fail2ban plus Docker services for WireGuard (`wg-easy`), AdGuard DNS, and Caddy internal TLS. It supports two operational paths:

- `site.yml` for an administrator-managed remote deployment.
- `install.sh` for a pinned, noninteractive-friendly fresh Debian/Ubuntu VPS install using `ansible-pull`.

Treat this as security-sensitive infrastructure. Preserve secret handling, SSH cutover rollback, firewall ordering, and service bootstrap state.

## Architecture & Data Flow

`site.yml` is the source-of-truth entry point. It runs two privileged `vps` plays, in order:

1. `roles/vps_hardening` (`hardening` tag): validates host capabilities, installs base packages, creates the admin user, sets sysctls, configures UFW, cuts SSH over to the new port, then configures fail2ban.
2. `roles/vps_orchestration` (`orchestration` tag): validates network/domain inputs, installs Docker, creates persistent volume paths, renders AdGuard and Compose configuration, deploys/reloads Caddy and Compose services, applies Docker/UFW rules, then verifies service reachability.

Role task entry points dynamically include phase files. Keep new work in the owning phase rather than growing `tasks/main.yml`. Configuration is rendered from role defaults and `group_vars/all`, then applied through Ansible modules and handlers. Orchestration templates produce Docker Compose, Caddy, and AdGuard configuration; verification fetches the generated Caddy root CA and tests service/container invariants.

Security-sensitive flows are deliberately fail-closed:

- SSH changes validate candidate configuration, flush handlers, wait for the new port, and rescue/restore on failure.
- UFW permits current/new SSH and WireGuard before default-deny/cutover actions.
- Caddy candidates are validated before activation; Compose bootstrap secrets are removed after initialization.
- Preflight probes use explicit assertions after non-mutating checks; do not hide a failed prerequisite with permissive `failed_when` logic.

## Key Directories

- `roles/vps_hardening/` — OS, user, SSH, UFW, sysctl, and fail2ban hardening role.
- `roles/vps_orchestration/` — Docker stack, persistent state, Caddy/AdGuard/WireGuard configuration, and runtime checks.
- `roles/*/tasks/` — phase-oriented task files; `tasks/main.yml` owns include order and tag boundaries.
- `roles/*/defaults/` — role configuration defaults. Keep deployment-specific secrets out of these files.
- `roles/*/templates/` — Jinja2 configuration templates, including `docker-compose.yml.j2`, `Caddyfile.j2`, and `AdGuardHome.yaml.j2`.
- `group_vars/all/` — operator variables and encrypted-vault examples. Copy `*.example` files; never commit real `vars.yml`, vault files, inventory, or fetched certificates.
- `inventory/` — `hosts.yml.example` for remote hosts; `localhost.yml` for controlled local/smoke scenarios.
- `scripts/` — contributor setup/check, operational backup, restore, synthetic-check, release-contract, and source-of-truth validation scripts.
- `tests/validation/` — deterministic Bash/Ansible fixture contracts; `manifest.txt` enumerates the contracts run by `scripts/check.sh`.
- `tests/e2e/` — QEMU/KVM and remote-install scenarios; not part of routine CI.
- `.github/workflows/ci.yml` — CI workflow; its static job runs the contributor bootstrap and quick-check entrypoints.
- `.github/workflows/release.yml` — tagged-release workflow; release validation is also available locally through `scripts/check.sh --release`.

## Development Commands

Set up the pinned controller dependencies and collections, then run the same fast checks as CI:

```bash
scripts/bootstrap.sh
scripts/check.sh
```

Prepare an encrypted remote deployment from examples:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all/vars.yml.example group_vars/all/vars.yml
cp group_vars/all/vault_services.yml.example group_vars/all/vault_services.yml
cp group_vars/all/vault_ssh.yml.example group_vars/all/vault_ssh.yml
ansible-vault encrypt group_vars/all/vault_services.yml group_vars/all/vault_ssh.yml
ansible-playbook --ask-vault-pass --syntax-check site.yml
ansible-playbook --ask-vault-pass site.yml -u root
```

Use targeted tags only when the phase boundary is intentional, for example:

```bash
ansible-playbook --ask-vault-pass site.yml --tags hardening -u root
ansible-playbook --ask-vault-pass site.yml --tags orchestration -u root
```

Do not rely on Ansible check mode for these roles: provisioning contains validation, stateful Docker bootstrap, service reloads, and SSH/UFW cutover logic that check mode cannot faithfully model.

Use `scripts/check.sh --e2e` for the fast checks plus the supported-platform QEMU install test. Use `scripts/check.sh --release` for the fast checks, QEMU install and lifecycle coverage, and release contracts.

For a focused validation, run the contract that covers the changed behavior directly. For example:

```bash
bash scripts/verify-ssot.sh
bash tests/validation/workflow-contract.sh
```

## Code Conventions & Common Patterns

- Use YAML document starts and the repository’s `.yamllint` rules. Keep lines at or below 140 characters where practical; explicit octal notation is prohibited.
- Name tasks as `Area | Phase | Action`. Keep tags on both include boundaries and task-level operations when a phase must be independently runnable.
- Use descriptive role-prefixed registered facts, such as `vps_hardening_*` and `vps_orchestration_*`.
- Prefer idempotent Ansible modules and declarative `state`. For necessary shell/command probes, define precise `changed_when` and `failed_when`, then assert expected output explicitly.
- Render secrets with restrictive modes and `no_log: true`; do not expose vault values, initial passwords, tokens, private keys, or generated extra-vars in task names, debug output, fixtures, or logs.
- Preserve `validate`, backup, rescue, handler, and `meta: flush_handlers` sequencing around SSH, UFW, Caddy, and Compose changes. These are safety mechanisms, not incidental complexity.
- Keep mutable service state in the existing volume/project-root paths. Avoid destructive volume recreation or direct service restarts that bypass the role’s validation/reload path.
- Reuse role defaults, `group_vars`, templates, and handlers rather than adding a parallel configuration source. Do not alter derived Docker architecture/repository/path variables without tracing their consumers.
- Ansible is the dependency-injection/state-management mechanism here: variables feed roles/templates, registered facts carry local state, and handlers apply deferred changes. There is no application framework or JavaScript package layer.

## Important Files

- `site.yml` — deployment entry point and role order.
- `ansible.cfg` — default `inventory/hosts.yml`, `roles_path=roles`, host-key checking, YAML output, SSH pipelining.
- `requirements.yml` — exact collection pins: `community.docker`, `community.general`, `ansible.posix`.
- `install.sh` — public installer contract, environment input validation, pinned checkout, temporary-secret cleanup, and local `ansible-pull` invocation.
- `README.md` — supported installation, remote deployment, operations, and development workflows.
- `.ansible-lint`, `.yamllint`, `.pre-commit-config.yaml` — formatting/lint/QA policy.
- `scripts/verify-ssot.sh` — source-of-truth cross-check; update its contracts when changing files or commands it validates.
- `scripts/bootstrap.sh`, `scripts/check.sh` — canonical contributor setup and validation entrypoints; `scripts/check.sh --release` adds release validation.
- `tests/validation/manifest.txt` — validation contracts executed by `scripts/check.sh`.

## Runtime/Tooling Preferences

- Use Python/Ansible tooling, not Node/Bun. There is no `package.json`, Makefile, or project package-manager manifest.
- `requirements-dev.txt` is the source of pinned controller and QA dependencies; `scripts/bootstrap.sh` installs it with the pinned collections in `requirements.yml`.
- `install.sh` targets a fresh Debian/Ubuntu VPS and requires root, `apt-get`, `/dev/net/tun`, and interactive `/dev/tty` unless `ZERO_TRUST_NONINTERACTIVE=1` is supplied. Use it only against a disposable/test VPS during development.
- `ansible.cfg` enables strict host-key checking. Do not weaken it to paper over connectivity failures.
- Keep generated inventories, real vaults, `.vault_password`, persistent volumes, and fetched certificates untracked as configured by `.gitignore`.

## Testing & QA

`.github/workflows/ci.yml` runs CI: its static job executes `scripts/bootstrap.sh` then `scripts/check.sh`, and its QEMU job runs the services-only install scenario. `.github/workflows/release.yml` owns tagged-release validation; run `scripts/check.sh --release` for the corresponding local release checks. Align changed commands or validation wiring with those entrypoints and `.pre-commit-config.yaml`.

The test suite is Bash/Ansible fixture based—there is no Molecule, pytest, tox, or coverage setup. Run the narrow contract that covers a changed behavior, for example:

```bash
bash tests/validation/ansible-runtime.sh
bash tests/validation/compose-render.sh
bash tests/validation/installer-contract.sh
bash tests/validation/backup-sandbox.sh
bash tests/validation/restore-sandbox.sh
```

`tests/validation/workflow-contract.sh` validates workflow and contributor-entrypoint structure. `scripts/check.sh` reads `tests/validation/manifest.txt` and runs every listed validation contract. When changing validation wiring, update the manifest as needed and verify the workflow/entrypoint structure with:

```bash
bash tests/validation/workflow-contract.sh
```

Use `tests/ansible-pull-smoke.yml` for the limited localhost `ansible-pull` inventory contract. Use the QEMU/KVM E2E scripts only for deployment/runtime changes that require real VM behavior; see `tests/e2e/README.md` and do not claim provider firewall/routing coverage from QEMU alone.
