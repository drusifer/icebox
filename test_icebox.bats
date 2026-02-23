#!/usr/bin/env bats
#
# Test script for ICEbox (In-memory Containerized Environment)
#
# This script uses bats-core to validate the functionality of Icebox.mk
# across different operational modes and lifecycle commands.
#
# Prerequisites:
# - bats-core installed (e.g., `sudo apt install bats` or `brew install bats-core`)
# - Podman installed and configured for rootless execution.
# - A public SSH key at ~/.ssh/id_ed25519.pub (or specified via SSH_KEY_PATH).
# - The ICEbox image built: `make build` from the icebox repo root.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# --- Global Variables ---

# Absolute path to Icebox.mk (in the icebox repo, not the test dir).
ICEBOX_MK="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/Icebox.mk"

# The directory where the test project will be created.
TEST_DIR=""

# The original current working directory (icebox repo root).
ORIGINAL_PWD="$(pwd)"

# The name of the test project (derived from TEST_DIR).
TEST_PROJECT_NAME=""

# The full path to the host's temporary directory for ICEbox caches.
HOST_ICEBOX_TMP_DIR=""

# The default user inside the container.
DEV_USER="iceman"

# The default home directory inside the container.
DEV_HOME="/home/${DEV_USER}"

# The default workspace directory inside the container.
DEV_WORKSPACE="/workspace"

# The default cache directory inside the container.
DEV_CACHE_DIR="${DEV_HOME}/.cache"

# Path to the SSH public key for testing.
TEST_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"

# Path to the SSH private key for testing.
TEST_SSH_PRIVATE_KEY_PATH="${HOME}/.ssh/id_ed25519"



# Container name derived from TEST_PROJECT_NAME.
CONTAINER_NAME=""

# SSH Port for the container.
CONTAINER_SSH_PORT=""

# --- Helper Functions ---

# Run a command inside the container via SSH.
# Usage: run_in_container "command string"
run_in_container() {
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${TEST_SSH_PRIVATE_KEY_PATH}" \
        -p "${CONTAINER_SSH_PORT}" \
        "${DEV_USER}@localhost" "$@"
}

# Invoke Icebox.mk from the test project directory.
# Usage: icebox_make <target> [VARIABLE=value ...]
icebox_make() {
    make -f "${ICEBOX_MK}" "$@"
}

# --- Setup and Teardown ---

setup() {
    # Create a temporary directory for the test project
    TEST_DIR="$(mktemp -d -t icebox-test-XXXXXX)"
    cd "${TEST_DIR}" || exit 1

    # Dynamically set project-specific names
    TEST_PROJECT_NAME=$(basename "${TEST_DIR}")
    CONTAINER_NAME="icebox-${TEST_PROJECT_NAME}"
    HOST_ICEBOX_TMP_DIR="/var/tmp/icebox/${TEST_PROJECT_NAME}"

    # Create a git repo so the .git mount works
    git init -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "initial content" > README.md
    git add README.md
    git commit -m "Initial commit"

    # Ensure SSH key exists for testing
    if [ ! -f "${TEST_SSH_KEY_PATH}" ]; then
        echo "Warning: SSH public key not found at ${TEST_SSH_KEY_PATH}. Generating one for testing." >&2
        ssh-keygen -t ed25519 -f "${TEST_SSH_PRIVATE_KEY_PATH}" -N "" -q
    fi

    # Clean up any previous test container for this project name
    icebox_make clean > /dev/null 2>&1 || true
}

teardown() {
    icebox_make clean > /dev/null 2>&1 || true
    cd "${ORIGINAL_PWD}" || exit 1
    rm -rf "${TEST_DIR}"
}

# --- Tests ---

@test "icebox target starts container and provides SSH config" {
    run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}"
    assert_success
    assert_output --partial "==> Container started."
    assert_output --partial "Host ${CONTAINER_NAME}"
    assert_output --partial "User ${DEV_USER}"

    # Extract SSH port
    CONTAINER_SSH_PORT=$(echo "$output" | grep "Port " | awk '{print $2}')
    [ -n "${CONTAINER_SSH_PORT}" ]

    # Verify container is running
    run podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}"
    assert_success
    assert_output "${CONTAINER_NAME}"

    # Verify SSH access
    run run_in_container "echo 'SSH connection successful'"
    assert_success
    assert_output --partial "SSH connection successful"

    # Verify DEV_USER inside container
    run run_in_container "whoami"
    assert_success
    assert_output --partial "${DEV_USER}"

    # Verify /workspace is tmpfs
    run run_in_container "findmnt -n -o FSTYPE ${DEV_WORKSPACE}"
    assert_success
    assert_output "tmpfs"

    # Verify /home/vscode is tmpfs
    run run_in_container "findmnt -n -o FSTYPE ${DEV_HOME}"
    assert_success
    assert_output "tmpfs"

    # Verify /home/vscode/.cache is a bind-mount (not tmpfs) in standard mode
    run run_in_container "findmnt -n -o FSTYPE ${DEV_CACHE_DIR}"
    assert_success
    refute_output "tmpfs"

    # Verify /icebox/.git is mounted
    run run_in_container "test -d /icebox/.git"
    assert_success

    # Verify read-only root filesystem
    run run_in_container "touch /test_file_on_root"
    assert_failure
    assert_output --partial "Read-only file system"

    # Verify internet access
    run run_in_container "curl -s -o /dev/null -w '%{http_code}' google.com"
    assert_success
    assert_output "301"
}

@test "standard mode: workspace is volatile, cache persists" {
    run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Write files in workspace and cache
    run run_in_container "echo 'workspace_data' > ${DEV_WORKSPACE}/test_file_workspace"
    assert_success
    run run_in_container "echo 'cache_data' > ${DEV_CACHE_DIR}/test_file_cache"
    assert_success

    # Restart container
    run icebox_make down > /dev/null
    assert_success
    run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Workspace file is gone
    run run_in_container "test -f ${DEV_WORKSPACE}/test_file_workspace"
    assert_failure

    # Cache file persists
    run run_in_container "cat ${DEV_CACHE_DIR}/test_file_cache"
    assert_success
    assert_output "cache_data"
}

@test "zero_leakage mode: workspace and cache are volatile" {
    run icebox_make icebox MODE=zero_leakage SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    run run_in_container "echo 'workspace_data_zl' > ${DEV_WORKSPACE}/test_file_zl"
    assert_success
    run run_in_container "echo 'cache_data_zl' > ${DEV_CACHE_DIR}/test_file_cache_zl"
    assert_success

    run icebox_make down > /dev/null
    assert_success
    run icebox_make icebox MODE=zero_leakage SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    run run_in_container "test -f ${DEV_WORKSPACE}/test_file_zl"
    assert_failure
    run run_in_container "test -f ${DEV_CACHE_DIR}/test_file_cache_zl"
    assert_failure
}

@test "resource_saver mode: workspace and cache persist" {
    run icebox_make icebox MODE=resource_saver SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    run run_in_container "echo 'workspace_data_rs' > ${DEV_WORKSPACE}/test_file_rs"
    assert_success
    run run_in_container "echo 'cache_data_rs' > ${DEV_CACHE_DIR}/test_file_cache_rs"
    assert_success

    run icebox_make down > /dev/null
    assert_success
    run icebox_make icebox MODE=resource_saver SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    run run_in_container "cat ${DEV_WORKSPACE}/test_file_rs"
    assert_success
    assert_output "workspace_data_rs"

    run run_in_container "cat ${DEV_CACHE_DIR}/test_file_cache_rs"
    assert_success
    assert_output "cache_data_rs"
}

@test "make down stops the container" {
    run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success

    run icebox_make down
    assert_success
    assert_output --partial "==> Stopping container"

    run podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}"
    assert_success
    assert_output ""
}

@test "make clean removes container and host artifacts" {
    run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success

    run icebox_make clean
    assert_success
    assert_output --partial "==> Cleaning up container and all artifacts"
    assert_output --partial "==> Deleting host cache directory..."
    assert_output --partial "==> Cleanup complete."

    run podman ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Names}}"
    assert_success
    assert_output ""

    run test -d "${HOST_ICEBOX_TMP_DIR}"
    assert_failure
}

@test ".git mount is writable: commits from container persist to host" {
    run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}"
    assert_success
    CONTAINER_SSH_PORT=$(echo "$output" | grep "Port " | awk '{print $2}')
    [ -n "${CONTAINER_SSH_PORT}" ]

    # Create a file, commit it, and push back to the host's .git
    run run_in_container "cd /workspace && echo 'from container' > container_file.txt && git add container_file.txt && git commit -m 'commit from container' && git push origin HEAD:main"
    assert_success

    # Verify the host's .git now contains the new commit
    run git -C "${TEST_DIR}" log --oneline -1
    assert_success
    assert_output --partial "commit from container"
}

@test "make pull syncs host working tree after container commit" {
    run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}"
    assert_success
    CONTAINER_SSH_PORT=$(echo "$output" | grep "Port " | awk '{print $2}')
    [ -n "${CONTAINER_SSH_PORT}" ]

    # Commit a new file from inside the container
    run run_in_container "cd /workspace && echo 'pulled content' > pull_test.txt && git add pull_test.txt && git commit -m 'add pull_test' && git push origin HEAD:main"
    assert_success

    # Host working tree does not yet have the file
    run test -f "${TEST_DIR}/pull_test.txt"
    assert_failure

    # Run make pull to sync host working tree
    run icebox_make pull
    assert_success
    assert_output --partial "==> Done. Working tree is up to date."

    # Host working tree now has the file
    run test -f "${TEST_DIR}/pull_test.txt"
    assert_success
    run cat "${TEST_DIR}/pull_test.txt"
    assert_success
    assert_output "pulled content"
}

@test "SSH agent is forwarded into container when SSH_AUTH_SOCK is set" {
    # Start a temporary SSH agent and add the test key
    AGENT_SOCK="/tmp/icebox-test-agent-$$.sock"
    eval "$(ssh-agent -s -a "${AGENT_SOCK}")"
    ssh-add "${TEST_SSH_PRIVATE_KEY_PATH}" 2>/dev/null

    SSH_AUTH_SOCK="${AGENT_SOCK}" \
        run icebox_make icebox SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" SSH_AUTH_SOCK="${AGENT_SOCK}"
    assert_success
    CONTAINER_SSH_PORT=$(echo "$output" | grep "Port " | awk '{print $2}')
    [ -n "${CONTAINER_SSH_PORT}" ]

    # SSH_AUTH_SOCK should be set inside the container
    run run_in_container "printenv SSH_AUTH_SOCK"
    assert_success
    assert_output "/tmp/ssh_auth_sock"

    # The socket file should exist inside the container
    run run_in_container "test -S /tmp/ssh_auth_sock"
    assert_success

    # Kill the temporary agent
    kill "${SSH_AGENT_PID}" 2>/dev/null || true
    rm -f "${AGENT_SOCK}"
}
