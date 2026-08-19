#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    printf 'usage: %s ROOT\n       %s --self-test\n' "$0" "$0" >&2
}

run_manifest_hooked() {
    local root="$1"
    OUTPUT_ROOT="$root" python3 - <<'PY'
import hashlib, os, stat
records = []
def kind(mode):
    return (b"d" if stat.S_ISDIR(mode) else b"f" if stat.S_ISREG(mode) else
            b"l" if stat.S_ISLNK(mode) else b"p" if stat.S_ISFIFO(mode) else
            b"s" if stat.S_ISSOCK(mode) else b"b" if stat.S_ISBLK(mode) else
            b"c" if stat.S_ISCHR(mode) else b"?")
def test_hook(tag):
    wanted = os.environ.get("ZT_OUTPUT_MANIFEST_TEST_HOOK_TAG")
    if wanted != tag:
        return
    event_fd = int(os.environ["ZT_OUTPUT_MANIFEST_TEST_EVENT_FD"])
    ack_fd = int(os.environ["ZT_OUTPUT_MANIFEST_TEST_ACK_FD"])
    os.write(event_fd, os.fsencode(tag) + b"\0")
    if os.read(ack_fd, 1) != b"1": raise RuntimeError("test hook was not acknowledged")
def walk(dirfd, rel=b"."):
    info = os.fstat(dirfd)
    records.append((rel, b"d", format(stat.S_IMODE(info.st_mode), "04o").encode(), b"-", b"-"))
    names_before = sorted(os.listdir(dirfd), key=os.fsencode)
    for name in names_before:
        encoded = os.fsencode(name); child = encoded if rel == b"." else rel + b"/" + encoded
        probe = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=dirfd)
        try: before = os.fstat(probe)
        finally: os.close(probe)
        mode = format(stat.S_IMODE(before.st_mode), "04o").encode(); entry_kind = kind(before.st_mode)
        if entry_kind == b"l":
            link_target = os.fsencode(os.readlink(name, dir_fd=dirfd))
            test_hook("symlink-before-verify:" + os.fsdecode(child))
            verify = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=dirfd)
            try: after = os.fstat(verify)
            finally: os.close(verify)
            if (before.st_dev, before.st_ino, before.st_mode) != (after.st_dev, after.st_ino, after.st_mode): raise RuntimeError("symlink race")
            records.append((child, entry_kind, mode, link_target, b"-"))
        elif entry_kind == b"d":
            childfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dirfd)
            try:
                after = os.fstat(childfd)
                if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("directory race")
                walk(childfd, child)
            finally: os.close(childfd)
        elif entry_kind == b"f":
            filefd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd); digest = hashlib.sha256()
            try:
                after = os.fstat(filefd)
                if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("file race")
                test_hook("file-before-read:" + os.fsdecode(child))
                while chunk := os.read(filefd, 1024 * 1024): digest.update(chunk)
                final = os.fstat(filefd)
                before_key = (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                final_key = (final.st_dev, final.st_ino, final.st_mode, final.st_size, final.st_mtime_ns, final.st_ctime_ns)
                if before_key != final_key: raise RuntimeError("file changed while hashing")
            finally: os.close(filefd)
            records.append((child, entry_kind, mode, b"-", digest.hexdigest().encode()))
        else: records.append((child, entry_kind, mode, b"-", b"-"))
    test_hook("directory-before-final-check:" + os.fsdecode(rel))
    if names_before != sorted(os.listdir(dirfd), key=os.fsencode): raise RuntimeError("directory changed while scanning")
rootfd = os.open(os.environ["OUTPUT_ROOT"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try: walk(rootfd)
finally: os.close(rootfd)
first_pass = sorted(records, key=lambda item: item[0]); records = []
test_hook("between-passes")
rootfd = os.open(os.environ["OUTPUT_ROOT"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try: walk(rootfd)
finally: os.close(rootfd)
if first_pass != sorted(records, key=lambda item: item[0]): raise RuntimeError("manifest changed between passes")
out = os.fdopen(os.dup(1), "wb", closefd=True)
out.write(b"format\0zt-output-manifest-v1\0")
for record in sorted(records, key=lambda item: item[0]): out.write(b"\0".join(record) + b"\0")
out.flush()
PY
}

run_manifest() {
    local root="$1"
    OUTPUT_ROOT="$root" python3 - <<'PY'
import hashlib, os, stat
records = []
def kind(mode):
    return (b"d" if stat.S_ISDIR(mode) else b"f" if stat.S_ISREG(mode) else
            b"l" if stat.S_ISLNK(mode) else b"p" if stat.S_ISFIFO(mode) else
            b"s" if stat.S_ISSOCK(mode) else b"b" if stat.S_ISBLK(mode) else
            b"c" if stat.S_ISCHR(mode) else b"?")
def walk(dirfd, rel=b"."):
    info = os.fstat(dirfd)
    records.append((rel, b"d", format(stat.S_IMODE(info.st_mode), "04o").encode(), b"-", b"-"))
    names_before = sorted(os.listdir(dirfd), key=os.fsencode)
    for name in names_before:
        encoded = os.fsencode(name); child = encoded if rel == b"." else rel + b"/" + encoded
        probe = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=dirfd)
        try: before = os.fstat(probe)
        finally: os.close(probe)
        mode = format(stat.S_IMODE(before.st_mode), "04o").encode(); entry_kind = kind(before.st_mode)
        if entry_kind == b"l":
            link_target = os.fsencode(os.readlink(name, dir_fd=dirfd))
            verify = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=dirfd)
            try: after = os.fstat(verify)
            finally: os.close(verify)
            if (before.st_dev, before.st_ino, before.st_mode) != (after.st_dev, after.st_ino, after.st_mode): raise RuntimeError("symlink race")
            records.append((child, entry_kind, mode, link_target, b"-"))
        elif entry_kind == b"d":
            childfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dirfd)
            try:
                after = os.fstat(childfd)
                if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("directory race")
                walk(childfd, child)
            finally: os.close(childfd)
        elif entry_kind == b"f":
            filefd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd); digest = hashlib.sha256()
            try:
                after = os.fstat(filefd)
                if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("file race")
                while chunk := os.read(filefd, 1024 * 1024): digest.update(chunk)
                final = os.fstat(filefd)
                before_key = (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                final_key = (final.st_dev, final.st_ino, final.st_mode, final.st_size, final.st_mtime_ns, final.st_ctime_ns)
                if before_key != final_key: raise RuntimeError("file changed while hashing")
            finally: os.close(filefd)
            records.append((child, entry_kind, mode, b"-", digest.hexdigest().encode()))
        else: records.append((child, entry_kind, mode, b"-", b"-"))
    if names_before != sorted(os.listdir(dirfd), key=os.fsencode): raise RuntimeError("directory changed while scanning")
rootfd = os.open(os.environ["OUTPUT_ROOT"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try: walk(rootfd)
finally: os.close(rootfd)
first_pass = sorted(records, key=lambda item: item[0]); records = []
rootfd = os.open(os.environ["OUTPUT_ROOT"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try: walk(rootfd)
finally: os.close(rootfd)
if first_pass != sorted(records, key=lambda item: item[0]): raise RuntimeError("manifest changed between passes")
out = os.fdopen(os.dup(1), "wb", closefd=True)
out.write(b"format\0zt-output-manifest-v1\0")
for record in sorted(records, key=lambda item: item[0]): out.write(b"\0".join(record) + b"\0")
out.flush()
PY
}

run_self_test() {
    local script_path="$1"
    python3 - "$script_path" <<'PY'
import os, shutil, signal, stat, subprocess, sys, tempfile, time

SCRIPT = os.path.realpath(sys.argv[1])
BOOTSTRAP = r'''
import hashlib, os, stat
records = []
def kind(mode):
    return (b"d" if stat.S_ISDIR(mode) else b"f" if stat.S_ISREG(mode) else
            b"l" if stat.S_ISLNK(mode) else b"p" if stat.S_ISFIFO(mode) else
            b"s" if stat.S_ISSOCK(mode) else b"b" if stat.S_ISBLK(mode) else
            b"c" if stat.S_ISCHR(mode) else b"?")
def walk(dirfd, rel=b"."):
    info = os.fstat(dirfd)
    records.append((rel, b"d", format(stat.S_IMODE(info.st_mode), "04o").encode(), b"-", b"-"))
    names_before = sorted(os.listdir(dirfd), key=os.fsencode)
    for name in names_before:
        encoded = os.fsencode(name); child = encoded if rel == b"." else rel + b"/" + encoded
        probe = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=dirfd)
        try: before = os.fstat(probe)
        finally: os.close(probe)
        mode = format(stat.S_IMODE(before.st_mode), "04o").encode(); entry_kind = kind(before.st_mode)
        if entry_kind == b"l":
            link_target = os.fsencode(os.readlink(name, dir_fd=dirfd))
            verify = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=dirfd)
            try: after = os.fstat(verify)
            finally: os.close(verify)
            if (before.st_dev, before.st_ino, before.st_mode) != (after.st_dev, after.st_ino, after.st_mode): raise RuntimeError("symlink race")
            records.append((child, entry_kind, mode, link_target, b"-"))
        elif entry_kind == b"d":
            childfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dirfd)
            try:
                after = os.fstat(childfd)
                if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("directory race")
                walk(childfd, child)
            finally: os.close(childfd)
        elif entry_kind == b"f":
            filefd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd); digest = hashlib.sha256()
            try:
                after = os.fstat(filefd)
                if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("file race")
                while chunk := os.read(filefd, 1024 * 1024): digest.update(chunk)
                final = os.fstat(filefd)
                before_key = (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                final_key = (final.st_dev, final.st_ino, final.st_mode, final.st_size, final.st_mtime_ns, final.st_ctime_ns)
                if before_key != final_key: raise RuntimeError("file changed while hashing")
            finally: os.close(filefd)
            records.append((child, entry_kind, mode, b"-", digest.hexdigest().encode()))
        else: records.append((child, entry_kind, mode, b"-", b"-"))
    if names_before != sorted(os.listdir(dirfd), key=os.fsencode): raise RuntimeError("directory changed while scanning")
rootfd = os.open(os.environ["OUTPUT_ROOT"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try: walk(rootfd)
finally: os.close(rootfd)
first_pass = sorted(records, key=lambda item: item[0]); records = []
rootfd = os.open(os.environ["OUTPUT_ROOT"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try: walk(rootfd)
finally: os.close(rootfd)
if first_pass != sorted(records, key=lambda item: item[0]): raise RuntimeError("manifest changed between passes")
out = os.fdopen(os.dup(1), "wb", closefd=True)
out.write(b"format\0zt-output-manifest-v1\0")
for record in sorted(records, key=lambda item: item[0]): out.write(b"\0".join(record) + b"\0")
out.flush()
'''
MUTATOR = r'''
import os, sys
root, action = sys.argv[1:]
if sys.stdin.buffer.read(1) != b"1":
    raise SystemExit(2)
if action == "file":
    with open(os.path.join(root, "racefile"), "r+b", buffering=0) as stream:
        stream.write(b"B")
        os.fsync(stream.fileno())
elif action == "symlink":
    replacement = os.path.join(root, "replacement")
    os.symlink("other", replacement)
    os.replace(replacement, os.path.join(root, "racelink"))
elif action == "directory":
    with open(os.path.join(root, "racedir", "new-entry"), "xb") as stream:
        stream.write(b"x")
elif action == "between-passes":
    with open(os.path.join(root, "stale"), "r+b", buffering=0) as stream:
        stream.write(b"B")
        os.fsync(stream.fileno())
else:
    raise SystemExit(2)
'''

tmp = tempfile.mkdtemp(prefix="zt-output-manifest.")
children = []

def interrupt(_signum, _frame):
    raise InterruptedError("self-test interrupted")

signal.signal(signal.SIGINT, interrupt)
signal.signal(signal.SIGTERM, interrupt)

def fail(message):
    raise AssertionError(message)

def invoke(root, extra_env=None):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.run([SCRIPT, root], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=env, check=False, timeout=15)

def bootstrap(root):
    env = os.environ.copy()
    env["OUTPUT_ROOT"] = root
    return subprocess.run([sys.executable, "-c", BOOTSTRAP], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, check=False, timeout=15)

def receive_event(fd):
    deadline = time.monotonic() + 10
    data = b""
    while not data.endswith(b"\0"):
        if time.monotonic() >= deadline:
            fail("synchronized race hook timed out")
        chunk = os.read(fd, 1)
        if not chunk:
            fail("synchronized race hook closed")
        data += chunk
    return os.fsdecode(data[:-1])

def race_case(action, hook):
    root = os.path.join(tmp, "race-" + action)
    os.mkdir(root)
    if action == "file":
        with open(os.path.join(root, "racefile"), "wb") as stream:
            stream.write(b"A")
    elif action == "symlink":
        os.symlink("target", os.path.join(root, "racelink"))
    elif action == "directory":
        os.mkdir(os.path.join(root, "racedir"))
    else:
        with open(os.path.join(root, "stale"), "wb") as stream:
            stream.write(b"A")
    event_read, event_write = os.pipe()
    ack_read, ack_write = os.pipe()
    mutator = None
    manifest = None
    try:
        env = os.environ.copy()
        env.update({
            "ZT_OUTPUT_MANIFEST_TEST_HOOK_TAG": hook,
            "ZT_OUTPUT_MANIFEST_TEST_EVENT_FD": str(event_write),
            "ZT_OUTPUT_MANIFEST_TEST_ACK_FD": str(ack_read),
        })
        manifest = subprocess.Popen([SCRIPT, root], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=env, pass_fds=(event_write, ack_read))
        children.append(manifest)
        os.close(event_write); event_write = -1
        os.close(ack_read); ack_read = -1
        if receive_event(event_read) != hook:
            fail("unexpected synchronized race hook")
        mutator = subprocess.Popen([sys.executable, "-c", MUTATOR, root, action], stdin=subprocess.PIPE,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.append(mutator)
        mutator.stdin.write(b"1")
        mutator.stdin.close()
        if mutator.wait(timeout=10) != 0:
            fail("mutator failed")
        os.write(ack_write, b"1")
        stdout, _stderr = manifest.communicate(timeout=10)
        if manifest.returncode == 0 or stdout:
            fail("mutation race was accepted")
    finally:
        for fd in (event_read, event_write, ack_read, ack_write):
            if fd != -1:
                try: os.close(fd)
                except OSError: pass
        for child in (mutator, manifest):
            if child is not None and child.poll() is None:
                child.terminate()
                child.wait(timeout=10)

try:
    root = os.path.join(tmp, "fixture")
    os.mkdir(root, 0o710)
    with open(os.path.join(root, "name with space"), "wb") as stream:
        stream.write(b"regular\n")
    os.chmod(os.path.join(root, "name with space"), 0o640)
    newline_name = os.path.join(root, "line\nbreak")
    with open(newline_name, "wb") as stream:
        stream.write(b"newline-name\n")
    os.chmod(newline_name, 0o600)
    os.mkdir(os.path.join(root, "nested"), 0o750)
    with open(os.path.join(root, "nested", "child"), "wb") as stream:
        stream.write(b"child\n")
    os.symlink("name with space", os.path.join(root, "link"))
    os.mkfifo(os.path.join(root, "pipe"), 0o620)
    os.chmod(os.path.join(root, "pipe"), 0o620)
    first = invoke(root)
    second = invoke(root)
    reference = bootstrap(root)
    if first.returncode != 0 or second.returncode != 0 or reference.returncode != 0:
        fail("normal fixture manifest failed")
    if first.stdout != second.stdout or first.stdout != reference.stdout:
        fail("manifest differed from bootstrap or repeat")
    if not first.stdout.startswith(b"format\0zt-output-manifest-v1\0"):
        fail("manifest header was not NUL-delimited")
    for token in (b"name with space", b"line\nbreak", b"link", b"pipe", b"f", b"l", b"p", b"0640", b"0600", b"0620"):
        if token not in first.stdout:
            fail("fixture record missing")
    missing = invoke(os.path.join(tmp, "missing"))
    nondirectory_path = os.path.join(tmp, "not-a-directory")
    with open(nondirectory_path, "wb") as stream:
        stream.write(b"x")
    nondirectory = invoke(nondirectory_path)
    symlink_root = os.path.join(tmp, "symlink-root")
    os.symlink(root, symlink_root)
    symlink = invoke(symlink_root)
    if any(result.returncode == 0 or result.stdout for result in (missing, nondirectory, symlink)):
        fail("invalid root was accepted")
    race_case("file", "file-before-read:racefile")
    race_case("symlink", "symlink-before-verify:racelink")
    race_case("directory", "directory-before-final-check:racedir")
    race_case("between-passes", "between-passes")
    for _ in range(2):
        sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        children.append(sleeper)
        sleeper.terminate()
        if sleeper.wait(timeout=10) != -signal.SIGTERM:
            fail("mutator termination was not observed")
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=10)
    shutil.rmtree(tmp, ignore_errors=True)

print("output-manifest self-test: PASS")
PY
}

if [[ $# -eq 1 && "$1" == "--self-test" ]]; then
    run_self_test "$0"
elif [[ $# -eq 1 && "$1" != --* ]]; then
    if [[ -n "${ZT_OUTPUT_MANIFEST_TEST_HOOK_TAG:-}" ]]; then
        run_manifest_hooked "$1"
    else
        run_manifest "$1"
    fi
else
    usage
    exit 2
fi
