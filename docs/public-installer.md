# Public v1.0 Installer Note

## Context

After the project stabilizes and reaches v1.0, the repository is expected to
become public and serve as a portfolio project.

For that release, the preferred public installation UX should be similar to
Docker's installer pattern:

```bash
curl -fsSL https://raw.githubusercontent.com/NikitaS2001/ansible-zero-trust-vps/v1.0.0/install.sh | sudo bash
```

## Direction

The public installer should be a thin entrypoint. It may install minimal local
prerequisites and then call `ansible-pull` against the canonical public
repository.

The installer must not become another source of truth. Configuration defaults,
templates, service versions, password hashing, firewall behavior, Docker
networking, and deployment logic should stay in Ansible roles.

## Design Rules

- Use a release tag such as `v1.0.0` in public quickstart commands, not `main`.
- Keep the script small: OS/root checks, prerequisites, and `ansible-pull`.
- Do not duplicate Ansible defaults or generated configuration in shell.
- Do not hash passwords in shell.
- Do not require GitHub credentials for the public quickstart path.
- Keep `bootstrap.sh` for local clone/development usage unless it is explicitly
  replaced.

## Follow-Up Before v1.0

- Decide whether `ansible-pull.sh` should be renamed or replaced by `install.sh`.
- Verify the full public bootstrap flow on a clean VPS.
- Run secret scanning against the full repository history before making it
  public.
- Update README quickstart sections to distinguish public install, local clone,
  and remote Ansible modes.
