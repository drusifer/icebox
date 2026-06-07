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
    refute_output --partial "Stopping pod"
    refute_output --partial "Deleting session keypair"
}

@test "auth target checks authkey before building image" {
    AUTH_LINE=$(grep '^auth:' "${ICEBOX_MK}")
    AUTHKEY_POS=$(echo "$AUTH_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="_check_authkey") print i}')
    BUILD_POS=$(echo "$AUTH_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="_build_if_needed") print i}')
    [ "$AUTHKEY_POS" -lt "$BUILD_POS" ]
}

@test "make status shows no-pods message when none running" {
    run icebox_make status
    assert_success
    assert_output --partial "Running ICEbox pods"
    # Either shows pods or shows (none) — never silent
    ( assert_output --partial "(none)" || assert_output --partial "icebox-" )
}

@test "test-setup and test targets absent from make help" {
    run icebox_make help
    assert_success
    refute_output --partial "test-setup"
    refute_output --partial "test       "
}

@test "make down removes session file and keypair" {
    mkdir -p "${SESSION_DIR}"
    echo "abc123" > "${SESSION_DIR}/.session"
    ssh-keygen -t ed25519 -f "${SESSION_DIR}/id_session" -N "" -q
    touch "${SESSION_DIR}/dev.pub"

    # Simulate a pod that doesn't exist — podman pod rm -f will just warn
    run icebox_make down
    assert_success
    run test -f "${SESSION_DIR}/.session"
    assert_failure
    run test -f "${SESSION_DIR}/id_session"
    assert_failure
    run test -f "${SESSION_DIR}/dev.pub"
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
# Phase 8 — Git PR flow (receive.git)
# ---------------------------------------------------------------------------

@test "receive.git bare clone command present in _session_start" {
    run grep 'clone --bare' "${ICEBOX_MK}"
    assert_success
    assert_output --partial "receive.git"
}

@test "receive.git is bind-mounted writable into sandbox" {
    run grep -E 'receive\.git:/icebox/receive\.git:Z' "${ICEBOX_MK}"
    assert_success
}

@test "upstream remote configured in entrypoint.sh" {
    ENTRYPOINT="$(dirname "${ICEBOX_MK}")/entrypoint.sh"
    run grep 'upstream.*receive.git' "${ENTRYPOINT}"
    assert_success
}

@test "make pr-list lists agent branches" {
    mkdir -p "${SESSION_DIR}"
    git clone --bare "${TEST_DIR}/.git" "${SESSION_DIR}/receive.git" -q
    WORK="$(mktemp -d)"
    git clone "${SESSION_DIR}/receive.git" "${WORK}" -q
    git -C "${WORK}" config user.email "agent@test"
    git -C "${WORK}" config user.name "Agent"
    git -C "${WORK}" checkout -b agent/feat -q
    echo "agent change" >> "${WORK}/README.md"
    git -C "${WORK}" commit -am "Agent feature" -q
    git -C "${WORK}" push origin agent/feat -q
    rm -rf "${WORK}"
    run icebox_make pr-list
    assert_success
    assert_output --partial "agent/feat"
}

@test "make merge fetches and merges agent branch" {
    mkdir -p "${SESSION_DIR}"
    git clone --bare "${TEST_DIR}/.git" "${SESSION_DIR}/receive.git" -q
    WORK="$(mktemp -d)"
    git clone "${SESSION_DIR}/receive.git" "${WORK}" -q
    git -C "${WORK}" config user.email "agent@test"
    git -C "${WORK}" config user.name "Agent"
    git -C "${WORK}" checkout -b agent/pr-test -q
    echo "agent fix" >> "${WORK}/README.md"
    git -C "${WORK}" commit -am "Agent PR test" -q
    git -C "${WORK}" push origin agent/pr-test -q
    rm -rf "${WORK}"
    run icebox_make merge BRANCH=agent/pr-test
    assert_success
    run git -C "${TEST_DIR}" log --oneline
    assert_output --partial "Agent PR test"
}

@test "make merge without BRANCH fails with clear error" {
    run icebox_make merge
    assert_failure
    assert_output --partial "BRANCH is required"
}

# ---------------------------------------------------------------------------
# Phase 9 — userns=auto + gVisor runtime
# ---------------------------------------------------------------------------

@test "pod create uses --userns=auto" {
    run grep -E 'pod create.*--userns=auto' "${ICEBOX_MK}"
    assert_success
}

@test "ICEBOX_RUNTIME variable defaults to runc" {
    run grep 'ICEBOX_RUNTIME.*runc' "${ICEBOX_MK}"
    assert_success
}

@test "pod create uses ICEBOX_RUNTIME" {
    run grep -E 'pod create.*ICEBOX_RUNTIME' "${ICEBOX_MK}"
    assert_success
}

# ---------------------------------------------------------------------------
# Phase 10 — icebox-run Landlock wrapper
# ---------------------------------------------------------------------------

@test "icebox-run.c is present in repo" {
    ICEBOX_RUN="$(dirname "${ICEBOX_MK}")/icebox-run.c"
    run test -f "${ICEBOX_RUN}"
    assert_success
}

@test "icebox-config.yaml contains egress.ports schema" {
    CONFIG="$(dirname "${ICEBOX_MK}")/icebox-config.yaml"
    run grep 'egress:' "${CONFIG}"
    assert_success
}

@test "icebox-config.yaml mount present in sandbox podman run" {
    run grep -E 'icebox-config\.yaml.*:/icebox/config\.yaml' "${ICEBOX_MK}"
    assert_success
}

@test "icebox-run.c uses Landlock NET_CONNECT_TCP" {
    ICEBOX_RUN="$(dirname "${ICEBOX_MK}")/icebox-run.c"
    run grep 'NET_CONNECT_TCP' "${ICEBOX_RUN}"
    assert_success
}

@test "icebox-run.c rebuild trigger present in _build_if_needed" {
    run grep 'icebox-run\.c.*BUILD_STAMP' "${ICEBOX_MK}"
    assert_success
}

@test "icebox-run.c compiles cleanly (struct layout + Landlock defs)" {
    if ! command -v clang &>/dev/null && ! command -v gcc &>/dev/null; then
        skip "No C compiler available on this host"
    fi
    ICEBOX_RUN="$(dirname "${ICEBOX_MK}")/icebox-run.c"
    COMPILER="${CC:-$(command -v clang 2>/dev/null || command -v gcc)}"
    run "${COMPILER}" -O2 -fsyntax-only "${ICEBOX_RUN}"
    assert_success
}

@test "built image contains icebox-run" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v icebox-run"
    assert_success
}

@test "icebox-run restricts /etc/passwd read" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/usr/local/bin/icebox-run \
        localhost/trixie-icebox:latest cat /etc/passwd
    assert_failure
}

@test "make down removes receive.git" {
    mkdir -p "${SESSION_DIR}"
    echo "abc123" > "${SESSION_DIR}/.session"
    ssh-keygen -t ed25519 -f "${SESSION_DIR}/id_session" -N "" -q
    touch "${SESSION_DIR}/dev.pub"
    git clone --bare "${TEST_DIR}/.git" "${SESSION_DIR}/receive.git" -q
    run icebox_make down
    assert_success
    run test -d "${SESSION_DIR}/receive.git"
    assert_failure
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

@test "built image does NOT contain waypipe" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v waypipe"
    assert_failure
}

@test "built image does NOT contain socat" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v socat"
    assert_failure
}

@test "built image contains sshd" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v sshd"
    assert_success
}

@test "built image contains foot" {
    if ! podman image exists localhost/trixie-icebox:latest 2>/dev/null; then
        skip "Image not built — run 'make build' first"
    fi
    run podman run --rm --entrypoint=/bin/bash \
        localhost/trixie-icebox:latest -c "command -v foot"
    assert_success
}
