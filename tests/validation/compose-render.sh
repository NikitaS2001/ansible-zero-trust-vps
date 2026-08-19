#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="${REPO_ROOT}/roles/vps_orchestration/templates/docker-compose.yml.j2"
TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/compose.yml"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/compose-render.XXXXXX")"
ACTIVE_COMPOSE_FILE=""
ACTIVE_OVERRIDE_FILE=""
cleanup() {
  if [[ -n "${ACTIVE_COMPOSE_FILE}" && -n "${ACTIVE_OVERRIDE_FILE}" ]]; then
    docker compose -f "${ACTIVE_COMPOSE_FILE}" -f "${ACTIVE_OVERRIDE_FILE}" \
      down --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "${FIXTURE_ROOT}"
}
trap cleanup EXIT INT TERM
chmod 700 "${FIXTURE_ROOT}"

render_case() {
  local case_name="$1"
  local vars_path="${FIXTURE_ROOT}/${case_name}.json"
  local expected_path="${FIXTURE_ROOT}/${case_name}.expected"
  local rendered_path="${FIXTURE_ROOT}/${case_name}.yml"
  local override_path="${FIXTURE_ROOT}/${case_name}.override.yml"
  local config_path="${FIXTURE_ROOT}/${case_name}.config.json"

  local project_root="${FIXTURE_ROOT}/${case_name}-project"
  mkdir -p "${project_root}/volumes/wg-easy" "${project_root}/Caddyfile.d"
  : >"${project_root}/Caddyfile"
  chmod 700 "${project_root}" "${project_root}/volumes" \
    "${project_root}/volumes/wg-easy" "${project_root}/Caddyfile.d"
  chmod 600 "${project_root}/Caddyfile"

  CASE_NAME="${case_name}" VARS_PATH="${vars_path}" EXPECTED_PATH="${expected_path}" \
    PROJECT_ROOT="${project_root}" python3 - <<'PY'
import json
import os
from pathlib import Path

passwords = {
    "dollar": "Twelve$COMPOSE_PROBE",
    "scalars": "  quote\" and ' colon: hash# backslash\\ spaces  ",
    "completed": "Twelve$COMPOSE_PROBE",
    "manual": "",
}
password = passwords[os.environ["CASE_NAME"]]
variables = {
    "adguard_bootstrap_ui_port": 3000,
    "adguard_container_ip": "10.66.0.2",
    "adguard_version": "v0.107.78",
    "caddy_container_ip": "10.66.0.3",
    "caddy_version": "2.11.4",
    "docker_network_subnet": "10.66.0.0/24",
    "project_root": os.environ["PROJECT_ROOT"],
    "wg_allowed_ips": ["10.8.0.0/24", "10.66.0.2/32"],
    "wg_client_dns": "10.66.0.2",
    "wg_container_port": 51820,
    "wg_easy_admin_password": password,
    "wg_easy_admin_user": "admin",
    "wg_easy_bootstrap_ui_port": 51821,
    "wg_easy_container_ip": "10.66.0.4",
    "wg_easy_include_init": os.environ["CASE_NAME"] in {"dollar", "scalars"},
    "wg_easy_version": "15.4.0",
    "wg_enable_ipv6": False,
    "wg_port": 51820,
    "wg_public_host": "vpn.example.test",
}
Path(os.environ["VARS_PATH"]).write_text(json.dumps(variables), encoding="utf-8")
Path(os.environ["EXPECTED_PATH"]).write_text(password, encoding="utf-8")
PY
  chmod 600 "${vars_path}" "${expected_path}"

  cat >"${FIXTURE_ROOT}/render.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  tasks:
    - name: Render the production Compose template
      ansible.builtin.template:
        src: "${TEMPLATE_PATH}"
        dest: "${rendered_path}"
        mode: '0600'
      no_log: true
YAML
  cat >"${override_path}" <<YAML
---
services:
  wg-easy:
    volumes:
      - "${expected_path}:/run/expected-password:ro"
YAML
  ANSIBLE_NOCOLOR=1 ansible-playbook -i localhost, -c local \
    "${FIXTURE_ROOT}/render.yml" -e "@${vars_path}" \
    >"${FIXTURE_ROOT}/${case_name}.ansible.log" 2>&1
  docker compose -f "${rendered_path}" -f "${override_path}" \
    config --format json \
    >"${config_path}" 2>"${FIXTURE_ROOT}/${case_name}.compose.log"
  chmod 600 "${override_path}" "${config_path}" \
    "${FIXTURE_ROOT}/${case_name}.ansible.log" \
    "${FIXTURE_ROOT}/${case_name}.compose.log"

  CASE_NAME="${case_name}" CONFIG_PATH="${config_path}" \
    EXPECTED_PATH="${expected_path}" python3 - <<'PY'
import json
import os
from pathlib import Path

config = json.loads(Path(os.environ["CONFIG_PATH"]).read_text(encoding="utf-8"))
expected = Path(os.environ["EXPECTED_PATH"]).read_text(encoding="utf-8")
environment = config["services"]["wg-easy"]["environment"]
expects_init = os.environ["CASE_NAME"] in {"dollar", "scalars"}
if not expects_init:
    if any(name.startswith("INIT_") for name in environment):
        raise SystemExit(1)
elif environment["INIT_PASSWORD"] != expected.replace("$", "$$"):
    print("password_exact=false")
    raise SystemExit(1)
PY

  if [[ "${case_name}" == "completed" || "${case_name}" == "manual" ]]; then
    return
  fi
  ACTIVE_COMPOSE_FILE="${rendered_path}"
  ACTIVE_OVERRIDE_FILE="${override_path}"
  docker compose -f "${rendered_path}" -f "${override_path}" \
    run --rm --no-deps --entrypoint node wg-easy -e \
    'const fs=require("fs");const expected=fs.readFileSync("/run/expected-password","utf8");process.exit(process.env.INIT_PASSWORD===expected?0:1)' \
    >"${FIXTURE_ROOT}/${case_name}.runtime.log" 2>&1
  chmod 600 "${FIXTURE_ROOT}/${case_name}.runtime.log"
  docker compose -f "${rendered_path}" -f "${override_path}" \
    down --remove-orphans >/dev/null 2>&1
  ACTIVE_COMPOSE_FILE=""
  ACTIVE_OVERRIDE_FILE=""
}

make_database() {
  local fixture_name="$1"
  local setup_step="$2"
  local fixture_dir="${FIXTURE_ROOT}/${fixture_name}/volumes/wg-easy"
  mkdir -p "${fixture_dir}"
  DB_PATH="${fixture_dir}/wg-easy.db" SETUP_STEP="${setup_step}" python3 - <<'PY'
import os
import sqlite3

connection = sqlite3.connect(os.environ["DB_PATH"])
connection.execute("CREATE TABLE general_table (setup_step INTEGER NOT NULL)")
connection.execute("INSERT INTO general_table (setup_step) VALUES (?)", (int(os.environ["SETUP_STEP"]),))
connection.commit()
connection.close()
PY
}

probe_case() {
  local fixture_name="$1"
  local expected="$2"
  local fixture_root="${FIXTURE_ROOT}/${fixture_name}"
  mkdir -p "${fixture_root}"
  cat >"${FIXTURE_ROOT}/probe-${fixture_name}.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  vars:
    project_root: "${fixture_root}"
  tasks:
    - ansible.builtin.import_tasks: "${TASK_PATH}"
    - name: Assert the production state decision
      ansible.builtin.assert:
        that:
          - (wg_easy_initialized | bool) == (${expected} | bool)
      tags: [wg_bootstrap_state]
YAML
  if ! ANSIBLE_NOCOLOR=1 ansible-playbook -i localhost, -c local \
    "${FIXTURE_ROOT}/probe-${fixture_name}.yml" --tags wg_bootstrap_state \
    >"${FIXTURE_ROOT}/probe-${fixture_name}.log" 2>&1; then
    chmod 600 "${FIXTURE_ROOT}/probe-${fixture_name}.log"
    return 1
  fi
  chmod 600 "${FIXTURE_ROOT}/probe-${fixture_name}.log"
}

probe_failure_case() {
  local fixture_name="$1"
  if probe_case "${fixture_name}" false; then
    return 1
  fi
}

render_case dollar
render_case scalars
render_case completed
render_case manual
printf '%s\n' 'password_exact=true' 'scalar_encoding=true' \
  'completed_secret_free=true' 'manual_wizard_secret_free=true'

probe_case absent false
make_database nonzero 2
probe_case nonzero false
make_database zero 0
probe_case zero true

mkdir -p "${FIXTURE_ROOT}/unexpected/volumes/wg-easy"
DB_PATH="${FIXTURE_ROOT}/unexpected/volumes/wg-easy/wg-easy.db" python3 - <<'PY'
import os
import sqlite3

connection = sqlite3.connect(os.environ["DB_PATH"])
connection.execute("CREATE TABLE unrelated (value INTEGER)")
connection.commit()
connection.close()
PY
probe_failure_case unexpected

mkdir -p "${FIXTURE_ROOT}/unreadable/volumes/wg-easy"
printf '%s' 'not-a-sqlite-database' >"${FIXTURE_ROOT}/unreadable/volumes/wg-easy/wg-easy.db"
probe_failure_case unreadable
printf '%s\n' 'state_absent=true' 'state_nonzero=true' 'state_zero=true' \
  'schema_fail_closed=true' 'unreadable_fail_closed=true'

COMPOSE_TASK_PATH="${TASK_PATH}" \
VERIFY_TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/verify.yml" python3 - <<'PY'
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

import yaml


def tasks_in(items):
    for task in items:
        yield task
        for section in ("block", "rescue", "always"):
            yield from tasks_in(task.get(section, []))


documents = []
for variable in ("COMPOSE_TASK_PATH", "VERIFY_TASK_PATH"):
    documents.extend(yaml.safe_load(Path(os.environ[variable]).read_text(encoding="utf-8")))

required_names = {
    "Compose | Detect | Select automated wg-easy bootstrap",
    "Compose | Deploy | Write docker-compose.yml",
    "Compose | Run | Start Docker Compose stack",
    "Compose | Bootstrap | Authenticate initial wg-easy setup",
    "Compose | Bootstrap | Authenticate re-secured wg-easy setup",
    "Compose | Rescue | Inspect scrubbed persistent Compose",
    "Compose | Rescue | Fail closed when persistent INIT variables remain",
    "Compose | Rescue | Inspect scrubbed wg-easy environment",
    "Compose | Rescue | Record credential scrub result",
    "Compose | Rescue | Fail closed when INIT_PASSWORD remains",
    "Compose | Rescue | Fail closed when unsafe INIT variables remain",
    "Verify | WG | wg-easy container env is free of INIT_PASSWORD",
}
tasks = {task.get("name"): task for task in tasks_in(documents)}
if not required_names.issubset(tasks):
    raise SystemExit(1)
for name in required_names:
    if tasks[name].get("no_log") in (None, False):
        raise SystemExit(1)

# Caddyfile is a Docker file bind-mount: replacing it with mv leaves the
# container on the old inode while .Caddyfile.active.sha256 tracks the new path.
inplace_names = (
    "Compose | Activate | Install validated Caddyfile in place",
    "Compose | Rollback | Restore prior managed file in place",
)
for name in inplace_names:
    if name not in tasks:
        raise SystemExit(1)
    argv = tasks[name].get("command", {}).get("argv") or []
    if len(argv) < 4 or argv[0] != "python3" or "-c" not in argv:
        raise SystemExit(1)
    script = argv[argv.index("-c") + 1]
    if "O_TRUNC" not in script or "O_WRONLY" not in script:
        raise SystemExit(1)
    if "os.rename" in script or "os.replace" in script:
        raise SystemExit(1)

script = tasks[inplace_names[0]]["command"]["argv"][
    tasks[inplace_names[0]]["command"]["argv"].index("-c") + 1
]
root = tempfile.mkdtemp(prefix="caddy-inode.")
try:
    live = os.path.join(root, "Caddyfile")
    candidate = os.path.join(root, "candidate")
    previous = os.path.join(root, "previous")
    with open(live, "w", encoding="utf-8") as handle:
        handle.write("old-config\n")
    with open(candidate, "w", encoding="utf-8") as handle:
        handle.write("new-config\n")
    with open(previous, "w", encoding="utf-8") as handle:
        handle.write("old-config\n")
    inode = os.stat(live).st_ino
    held_fd = os.open(live, os.O_RDONLY)
    subprocess.check_call(["python3", "-c", script, candidate, live])
    if os.stat(live).st_ino != inode:
        raise SystemExit(1)
    if os.read(held_fd, 64) != b"new-config\n":
        raise SystemExit(1)
    if stat.S_IMODE(os.stat(live).st_mode) != 0o600:
        raise SystemExit(1)
    os.lseek(held_fd, 0, os.SEEK_SET)
    subprocess.check_call(["python3", "-c", script, previous, live])
    if os.stat(live).st_ino != inode:
        raise SystemExit(1)
    if os.read(held_fd, 64) != b"old-config\n":
        raise SystemExit(1)
    os.close(held_fd)

    # Contrast: mv/replace creates a new inode and leaves the held fd stale.
    with open(live, "w", encoding="utf-8") as handle:
        handle.write("old-config\n")
    with open(candidate, "w", encoding="utf-8") as handle:
        handle.write("new-config\n")
    stale_inode = os.stat(live).st_ino
    stale_fd = os.open(live, os.O_RDONLY)
    os.replace(candidate, live)
    if os.stat(live).st_ino == stale_inode:
        raise SystemExit(1)
    if os.read(stale_fd, 64) != b"old-config\n":
        raise SystemExit(1)
    os.close(stale_fd)
finally:
    shutil.rmtree(root, ignore_errors=True)
PY
printf '%s\n' 'credential_tasks_no_log=true' 'cleanup_registered=true' \
  'caddy_bind_mount_inode=true'
