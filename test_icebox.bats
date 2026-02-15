#!/usr/bin/env bats
#
# Test script for ICEbox (In-memory Containerized Environment)
#
# This script uses bats-core to validate the functionality of the ICEbox Makefile
# across different operational modes and lifecycle commands.
#
# Prerequisites:
# - bats-core installed (e.g., `sudo apt install bats` or `brew install bats-core`)
# - Podman installed and configured for rootless execution.
# - A public SSH key at ~/.ssh/id_ed25519.pub (or specified via SSH_KEY_PATH).
# - The base image 'mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04' available locally.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# --- Global Variables ---

# The directory where the test will run.
TEST_DIR=""

# The original current working directory.
ORIGINAL_PWD="$(pwd)"

# The name of the test project.
TEST_PROJECT_NAME=""

# The full path to the host's temporary directory for ICEbox caches.
HOST_ICEBOX_TMP_DIR=""

# The default user inside the container.
DEV_USER="vscode"

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
# Function to run a command inside the container via SSH.
# Usage: run_in_container "command string"
run_in_container() {
   ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -i "${TEST_SSH_PRIVATE_KEY_PATH}" \
        -p "${CONTAINER_SSH_PORT}" "${DEV_USER}@localhost" "$@"
}

# --- Setup and Teardown ---
setup() {
    # Create a temporary directory for the test project
    TEST_DIR="$(mktemp -d -t icebox-test-XXXXXX)"
    cd "${TEST_DIR}" || exit 1

    # Dynamically set project-specific names based on the temp directory
    # This makes tests more robust and allows for potential parallel execution.
    TEST_PROJECT_NAME=$(basename "${TEST_DIR}")
    CONTAINER_NAME="icebox-${TEST_PROJECT_NAME}"
    HOST_ICEBOX_TMP_DIR="/var/tmp/icebox/${TEST_PROJECT_NAME}"

    # Create a dummy .git directory
    mkdir .git
    git init --bare .git
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "initial commit" > README.md
    git add README.md
    git commit -m "Initial commit"

    # Copy Makefile and entrypoint.sh
    cp "${ORIGINAL_PWD}/Makefile" .
    cp "${ORIGINAL_PWD}/entrypoint.sh" .

    # Ensure SSH key exists for testing
    if [ ! -f "${TEST_SSH_KEY_PATH}" ]; then
        echo "Warning: SSH public key not found at ${TEST_SSH_KEY_PATH}. Generating one for testing." >&2
        ssh-keygen -t ed25519 -f "${TEST_SSH_PRIVATE_KEY_PATH}" -N "" -q
    fi

    # Clean up any previous test runs
    run make clean > /dev/null 2>&1 || true
}

teardown() {
    # Ensure container is stopped and cleaned up
    run make clean > /dev/null 2>&1 || true

    # Go back to original directory and remove test directory
    cd "${ORIGINAL_PWD}" || exit 1
    rm -rf "${TEST_DIR}"
}

# --- Tests ---

@test "make up (standard mode) starts container and provides SSH config" {
    # Run make up in standard mode
    run make up SSH_KEY_PATH="${TEST_SSH_KEY_PATH}"
    assert_success
    assert_output --partial "==> Container started."
    assert_output --partial "Host ${CONTAINER_NAME}"
    assert_output --partial "User ${DEV_USER}"

    # Extract SSH port from output
    CONTAINER_SSH_PORT=$(echo "$output" | grep "Port " | awk '{print $2}')
    [ -n "${CONTAINER_SSH_PORT}" ]

    # Verify container is running
    run podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}"
    assert_success
    assert_output "${CONTAINER_NAME}"

    # Verify SSH access
    run run_in_container "echo 'SSH connection successful'"
    assert_success
    assert_output "SSH connection successful"

    # Verify DEV_USER is correct inside
    run run_in_container "whoami"
    assert_success
    assert_output "${DEV_USER}"

    # Verify /workspace is tmpfs
    run run_in_container "findmnt -n -o FSTYPE ${DEV_WORKSPACE}"
    assert_success
    assert_output "tmpfs"

    # Verify /home/vscode is tmpfs
    run run_in_container "findmnt -n -o FSTYPE ${DEV_HOME}"
    assert_success
    assert_output "tmpfs"

    # Verify /home/vscode/.cache is a bind-mount to host /var/tmp
    run run_in_container "findmnt -n -o SOURCE ${DEV_CACHE_DIR}"
    assert_success
    assert_output --partial "${HOST_ICEBOX_TMP_DIR}/caches"

    # Verify /icebox/.git is mounted
    run run_in_container "test -d /icebox/.git"
    assert_success

    # Verify read-only root filesystem
    run run_in_container "touch /test_file_on_root"
    assert_failure
    assert_output --partial "Permission denied"

    # Verify internet access
    run run_in_container "curl -s -o /dev/null -w '%{http_code}' google.com"
    assert_success
    assert_output "301" # Google redirects, so 301 is expected
}

@test "standard mode: workspace is volatile, cache persists" {
    # Ensure container is up in standard mode
    run make up SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Create a file in workspace
    run run_in_container "echo 'workspace_data' > ${DEV_WORKSPACE}/test_file_workspace"
    assert_success
    run run_in_container "test -f ${DEV_WORKSPACE}/test_file_workspace"
    assert_success

    # Create a file in cache
    run run_in_container "echo 'cache_data' > ${DEV_CACHE_DIR}/test_file_cache"
    assert_success
    run run_in_container "test -f ${DEV_CACHE_DIR}/test_file_cache"
    assert_success

    # Stop and restart container
    run make down > /dev/null
    assert_success
    run make up SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Verify workspace file is gone
    run run_in_container "test -f ${DEV_WORKSPACE}/test_file_workspace"
    assert_failure

    # Verify cache file persists
    run run_in_container "cat ${DEV_CACHE_DIR}/test_file_cache"
    assert_success
    assert_output "cache_data"
}

@test "zero_leakage mode: workspace and cache are volatile" {
    # Ensure container is up in zero_leakage mode
    run make up MODE=zero_leakage SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Create a file in workspace
    run run_in_container "echo 'workspace_data_zl' > ${DEV_WORKSPACE}/test_file_workspace_zl"
    assert_success
    run run_in_container "test -f ${DEV_WORKSPACE}/test_file_workspace_zl"
    assert_success

    # Create a file in cache
    run run_in_container "echo 'cache_data_zl' > ${DEV_CACHE_DIR}/test_file_cache_zl"
    assert_success
    run run_in_container "test -f ${DEV_CACHE_DIR}/test_file_cache_zl"
    assert_success

    # Stop and restart container
    run make down > /dev/null
    assert_success
    run make up MODE=zero_leakage SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Verify workspace file is gone
    run run_in_container "test -f ${DEV_WORKSPACE}/test_file_workspace_zl"
    assert_failure

    # Verify cache file is gone
    run run_in_container "test -f ${DEV_CACHE_DIR}/test_file_cache_zl"
    assert_failure
}

@test "resource_saver mode: workspace and cache persist" {
    # Ensure container is up in resource_saver mode
    run make up MODE=resource_saver SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Create a file in workspace
    run run_in_container "echo 'workspace_data_rs' > ${DEV_WORKSPACE}/test_file_workspace_rs"
    assert_success
    run run_in_container "test -f ${DEV_WORKSPACE}/test_file_workspace_rs"
    assert_success

    # Create a file in cache
    run run_in_container "echo 'cache_data_rs' > ${DEV_CACHE_DIR}/test_file_cache_rs"
    assert_success
    run run_in_container "test -f ${DEV_CACHE_DIR}/test_file_cache_rs"
    assert_success

    # Stop and restart container
    run make down > /dev/null
    assert_success
    run make up MODE=resource_saver SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success
    CONTAINER_SSH_PORT=$(podman port "${CONTAINER_NAME}" 22/tcp | cut -d: -f2)

    # Verify workspace file persists
    run run_in_container "cat ${DEV_WORKSPACE}/test_file_workspace_rs"
    assert_success
    assert_output "workspace_data_rs"

    # Verify cache file persists
    run run_in_container "cat ${DEV_CACHE_DIR}/test_file_cache_rs"
    assert_success
    assert_output "cache_data_rs"
}

@test "make down stops the container" {
    # Ensure container is up
    run make up SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success

    # Stop the container
    run make down
    assert_success
    assert_output --partial "==> Stopping container"

    # Verify container is not running
    run podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}"
    assert_success
    assert_output ""
}

@test "make clean removes container and host artifacts" {
    # Ensure container is up (and thus host artifacts exist)
    run make up SSH_KEY_PATH="${TEST_SSH_KEY_PATH}" > /dev/null
    assert_success

    # Clean up
    run make clean
    assert_success
    assert_output --partial "==> Cleaning up container and all artifacts"
    assert_output --partial "==> Deleting host cache directory..."
    assert_output --partial "==> Cleanup complete."

    # Verify container is gone
    run podman ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Names}}"
    assert_success
    assert_output ""

    # Verify host cache directory is removed
    run test -d "${HOST_ICEBOX_TMP_DIR}"
    assert_failure
}
