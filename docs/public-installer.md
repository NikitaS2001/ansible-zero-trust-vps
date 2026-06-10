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

The v1.0 public installer is `install.sh`. The existing `bootstrap.sh` remains
the local clone/development entrypoint. The existing `ansible-pull.sh` is not
the public quickstart interface and may be removed or folded into `install.sh`
after the public installer has stabilized.

The installer UX is interactive, but uses strict single-source-of-truth
defaults: prompts may allow the user to press Enter for the role default, but
the shell script must not duplicate the concrete Ansible defaults.

## Design Rules

- Use a release tag such as `v1.0.0` in public quickstart commands, not `main`.
- Keep the script small: OS/root checks, prerequisites, and `ansible-pull`.
- Do not duplicate Ansible defaults or generated configuration in shell.
- Do not hash passwords in shell.
- Do not require GitHub credentials for the public quickstart path.
- Keep `bootstrap.sh` for local clone/development usage unless it is explicitly
  replaced.
- Install Ansible collections through `ansible-galaxy collection install -r
  requirements.yml`, not by installing collections as Python packages.
- Read interactive prompts from `/dev/tty` so the documented `curl | sudo bash`
  command can still ask questions.

## Follow-Up Before v1.0

- Verify the full public bootstrap flow on a clean VPS.
- Run secret scanning against the full repository history before making it
  public.
- Verify that the tagged `v1.0.0` quickstart command installs from the tag, not
  from `main`.
