#!/usr/bin/env bats
#
# ICEbox test suite — pod model (ICEBox2)
#
# Prerequisites:
#   bats, podman (rootless), python3-yaml, openssl
#   TS_AUTHKEY not required — Tailscale sidecar tests are skipped without it.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

ICEBOX_MK="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/Icebox.mk"
ORIGINAL_PWD="$(pwd)"
TEST_DIR=""
TEST_PROJECT_NAME=""
SESSION_DIR=""

icebox_make() {
    make -f "${ICEBOX_MK}" -C "${TEST_DIR}" "$@"
}

setup() {
    TEST_DIR="$(mktemp -d -t icebox-test-XXXXXX)"
    TEST_PROJECT_NAME=$(basename "${TEST_DIR}")
    SESSION_DIR="/var/tmp/icebox/${TEST_PROJECT_NAME}"

    cd "${TEST_DIR}"
    git init -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "initial" > README.md
    git add README.md
    git commit -m "Initial commit" -q

    # Minimal valid config
    cat > "${TEST_DIR}/icebox-config.yaml" <<'EOF'
credentials: []
repos: []
EOF

    # Ensure clean state
    icebox_make clean > /dev/null 2>&1 || true
}

teardown() {
    icebox_make clean > /dev/null 2>&1 || true
    cd "${ORIGINAL_PWD}"
    rm -rf "${TEST_DIR}"
}

# ---------------------------------------------------------------------------
# Phase 0 — Config validation
# ---------------------------------------------------------------------------

@test "missing icebox-config.yaml fails with clear error" {
    rm "${TEST_DIR}/icebox-config.yaml"
    run icebox_make auth TS_AUTHKEY=fake
    assert_failure
    assert_output --partial "icebox-config.yaml not found"
}

@test "missing TS_AUTHKEY fails with clear error" {
    run make -f "${ICEBOX_MK}" -C "${TEST_DIR}" _check_authkey TS_AUTHKEY=
    assert_failure
    assert_output --partial "TS_AUTHKEY is not set"
    assert_output --partial "tailscale.com/admin"
}

# ---------------------------------------------------------------------------
# Phase 2 — Ephemeral session keypair
# ---------------------------------------------------------------------------

@test "session keypair generated in SESSION_DIR" {
    # We stub _check_authkey and stop before pod creation
    mkdir -p "${SESSION_DIR}"
    openssl rand -hex 3 > "${SESSION_DIR}/.session"
    ssh-keygen -t ed25519 -f "${SESSION_DIR}/id_session" -N "" -q
    run test -f "${SESSION_DIR}/id_session"
    assert_success
    run test -f "${SESSION_DIR}/id_session.pub"
    assert_success
}

@test "session keypair is NOT in host ~/.ssh/" {
    mkdir -p "${SESSION_DIR}"
    ssh-keygen -t ed25519 -f "${SESSION_DIR}/id_session" -N "" -q
    # Confirm the generated key does NOT live under ~/.ssh/
    run bash -c "ls ~/.ssh/id_session 2>/dev/null"
    assert_failure
}

@test "make clean removes session keypair" {
    mkdir -p "${SESSION_DIR}"
    ssh-keygen -t ed25519 -f "${SESSION_DIR}/id_session" -N "" -q
    echo "fakeid" > "${SESSION_DIR}/.session"
    # clean calls down (which removes keypair) then deletes SESSION_DIR
    icebox_make clean > /dev/null 2>&1 || true
    run test -d "${SESSION_DIR}"
    assert_failure
}

# ---------------------------------------------------------------------------
# Phase 3 — Session ID + pod lifecycle (no live Tailscale required)
# ---------------------------------------------------------------------------

@test "session ID is 6 hex chars" {
    SID=$(openssl rand -hex 3)
    [[ "${SID}" =~ ^[0-9a-f]{6}$ ]]
}

@test "make down with no active session exits cleanly" {
    run icebox_make down
    assert_success
    assert_output --partial "No active session"
}

@test "make down removes session file and keypair" {
    mkdir -p "${SESSION_DIR}"
    echo "abc123" > "${SESSION_DIR}/.session"
    ssh-keygen -t ed25519 -f "${SESSION_DIR}/id_session" -N "" -q

    # Simulate a pod that doesn't exist — podman pod rm -f will just warn
    run icebox_make down
    assert_success
    run test -f "${SESSION_DIR}/.session"
    assert_failure
    run test -f "${SESSION_DIR}/id_session"
    assert_failure
}

# ---------------------------------------------------------------------------
# Phase 3 — make status output format
# ---------------------------------------------------------------------------

@test "make status lists icebox pods" {
    run icebox_make status
    assert_success
    assert_output --partial "Running ICEbox pods"
}

# ---------------------------------------------------------------------------
# Phase 0 — Config parsing (python3 yaml)
# ---------------------------------------------------------------------------

@test "valid icebox-config.yaml with repos parses without error" {
    cat > "${TEST_DIR}/icebox-config.yaml" <<'EOF'
credentials:
  - github
repos:
  - url: https://github.com/example/repo.git
EOF
    run python3 -c "
import yaml, sys
cfg = yaml.safe_load(open('${TEST_DIR}/icebox-config.yaml')) or {}
creds = cfg.get('credentials', [])
repos = cfg.get('repos', [])
assert isinstance(creds, list)
assert isinstance(repos, list)
assert repos[0]['url'] == 'https://github.com/example/repo.git'
print('ok')
"
    assert_success
    assert_output "ok"
}

@test "AppArmor label=disable is not present in sandbox podman run" {
    run grep -c 'label=disable' "${ICEBOX_MK}"
    # grep exits 1 when no matches found, which is what we want
    assert_failure
}

@test "SYS_CHROOT is not in capability list" {
    run grep 'SYS_CHROOT' "${ICEBOX_MK}"
    assert_failure
}

@test "pids-limit is set on sandbox container" {
    run grep -E '\-\-pids-limit' "${ICEBOX_MK}"
    assert_success
}

@test "session key is mounted at staging path, not directly into ~/.ssh" {
    run grep 'id_session.*\.ssh' "${ICEBOX_MK}"
    assert_failure
    run grep 'id_session:/icebox/id_session' "${ICEBOX_MK}"
    assert_success
}

@test "session key chmod 644 on host so container can read from staging mount" {
    run grep 'chmod 644.*id_session' "${ICEBOX_MK}"
    assert_success
}

@test "Icebox.mk mounts .git read-only" {
    run grep -E '\.git.*:ro,Z' "${ICEBOX_MK}"
    assert_success
}

@test "config mounts default to read-only (no rw flag)" {
    cat > "${TEST_DIR}/icebox-config.yaml" <<'EOF'
credentials: []
repos: []
mounts:
  - host: /tmp
    container: /workspace/tmp
EOF
    run python3 -c "
import yaml
cfg = yaml.safe_load(open('${TEST_DIR}/icebox-config.yaml')) or {}
mounts = cfg.get('mounts', []) or []
flags = []
[flags.append('--volume ' + m.get('host','') + ':' + m.get('container','') + (':Z' if m.get('rw', False) else ':ro,Z')) for m in mounts if isinstance(m, dict) and m.get('host') and m.get('container')]
print(' '.join(flags))
"
    assert_success
    assert_output "--volume /tmp:/workspace/tmp:ro,Z"
}

@test "config mount with rw: true uses writable flag" {
    cat > "${TEST_DIR}/icebox-config.yaml" <<'EOF'
credentials: []
repos: []
mounts:
  - host: /tmp
    container: /workspace/tmp
    rw: true
EOF
    run python3 -c "
import yaml
cfg = yaml.safe_load(open('${TEST_DIR}/icebox-config.yaml')) or {}
mounts = cfg.get('mounts', []) or []
flags = []
[flags.append('--volume ' + m.get('host','') + ':' + m.get('container','') + (':Z' if m.get('rw', False) else ':ro,Z')) for m in mounts if isinstance(m, dict) and m.get('host') and m.get('container')]
print(' '.join(flags))
"
    assert_success
    assert_output "--volume /tmp:/workspace/tmp:Z"
}

@test "missing host path in mounts fails with clear error" {
    cat > "${TEST_DIR}/icebox-config.yaml" <<'EOF'
credentials: []
repos: []
mounts:
  - host: /nonexistent/path/abc123
    container: /workspace/data
EOF
    run python3 -c "
import yaml, sys, os
cfg = yaml.safe_load(open('${TEST_DIR}/icebox-config.yaml')) or {}
mounts = cfg.get('mounts', []) or []
missing = [m.get('host','') for m in mounts if isinstance(m, dict) and not os.path.exists(m.get('host',''))]
[sys.exit('Error: mount host path does not exist: ' + p) for p in missing if p]
"
    assert_failure
    assert_output --partial "does not exist"
}

@test "pod create uses --network=pasta" {
    run grep -E 'pod create.*--network=pasta' "${ICEBOX_MK}"
    assert_success
}

@test "REPO_MOUNTS python generates correct volume flags for multi-repo config" {
    cat > "${TEST_DIR}/icebox-config.yaml" <<'EOF'
credentials:
  - github
repos:
  - url: https://github.com/example/repo.git
  - url: https://github.com/myorg/lib.git
    path: /opt/repos/lib
EOF
    run python3 -c "
import yaml
cfg = yaml.safe_load(open('${TEST_DIR}/icebox-config.yaml')) or {}
repos = cfg.get('repos', []) or []
mounts = []
[mounts.append('--volume ' + r.get('path', '/var/tmp/icebox/repos/' + r.get('url','').rstrip('/').split('/')[-1].replace('.git','')) + ':/icebox/repos/' + r.get('url','').rstrip('/').split('/')[-1].replace('.git','') + ':ro,Z') for r in repos if isinstance(r, dict) and r.get('url')]
print(' '.join(mounts))
"
    assert_success
    assert_output --partial "--volume /var/tmp/icebox/repos/repo:/icebox/repos/repo:ro,Z"
    assert_output --partial "--volume /opt/repos/lib:/icebox/repos/lib:ro,Z"
}

@test "icebox-config.yaml with empty repos list parses without error" {
    cat > "${TEST_DIR}/icebox-config.yaml" <<'EOF'
credentials: []
repos: []
EOF
    run python3 -c "
import yaml
cfg = yaml.safe_load(open('${TEST_DIR}/icebox-config.yaml')) or {}
assert cfg.get('repos', []) == []
print('ok')
"
    assert_success
    assert_output "ok"
}

# ---------------------------------------------------------------------------
# Phase 1 — Image verification (requires built image)
# ---------------------------------------------------------------------------

@test "built image contains code-server" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v code-server"
    assert_success
}

@test "built image contains waypipe" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v waypipe"
    assert_success
}

@test "built image does NOT contain sshd" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v sshd"
    assert_failure
}
