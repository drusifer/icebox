#!/bin/bash
set -e

# This script is the entrypoint for the ICEbox container.
# It performs final setup steps before starting the SSH server.

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"

echo "==> ICEbox entrypoint started."

# 1. Verify the dev user exists
if ! id -u "${DEV_USER}" >/dev/null 2>&1; then
    echo "Error: User '${DEV_USER}' not found in the container image."
    echo "Please use a different base image or set DEV_USER to a valid user."
    exit 1
fi

# 2. Set up SSH access for the user
if [ -z "${ICEBOX_SSH_PUB_KEY}" ]; then
    echo "Error: ICEBOX_SSH_PUB_KEY environment variable is not set. Cannot configure SSH."
    exit 1
fi

echo "==> Configuring SSH access..."
chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"
# Ensure .cache ownership is correct (bind mount may be owned by root)
if [ -d "${DEV_HOME}/.cache" ]; then
    chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.cache"
fi
mkdir -p "${DEV_HOME}/.ssh"
echo "${ICEBOX_SSH_PUB_KEY}" > "${DEV_HOME}/.ssh/authorized_keys"

# Set correct permissions
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh"
chmod 700 "${DEV_HOME}/.ssh"
chmod 600 "${DEV_HOME}/.ssh/authorized_keys"

# 3. Restore git workspace
if [ -d "/icebox/.git" ]; then
    echo "==> Restoring git workspace..."

    # Detect the active branch from the host's .git directory
    if [ -n "${ICEBOX_GIT_BRANCH}" ]; then
        BRANCH="${ICEBOX_GIT_BRANCH}"
    elif [ -f "/icebox/.git/HEAD" ]; then
        HEAD_CONTENT=$(cat /icebox/.git/HEAD)
        if echo "${HEAD_CONTENT}" | grep -q "^ref: refs/heads/"; then
            BRANCH=$(echo "${HEAD_CONTENT}" | sed 's|^ref: refs/heads/||')
        else
            # Detached HEAD — use the commit hash directly
            BRANCH="${HEAD_CONTENT}"
        fi
    else
        BRANCH="main"
    fi

    # Allow git push from inside the container to persist commits to the host .git.
    # receive.denyCurrentBranch=ignore: accept pushes to the checked-out branch and
    # update only the ref, not the working tree (the working tree is not accessible
    # inside the container since only .git is bind-mounted, not the full project dir).
    # Run `make pull` on the host after pushing to sync the working tree.
    git config --file /icebox/.git/config receive.denyCurrentBranch ignore

    chown "${DEV_USER}:${DEV_USER}" /workspace
    cd /workspace
    git init
    git config --global safe.directory /icebox/.git
    git remote add origin /icebox/.git
    git fetch origin
    git checkout "${BRANCH}"
    echo "cd /workspace" >> "${DEV_HOME}/.bashrc"
    echo "==> Git workspace restored (branch: ${BRANCH})."
fi

# 3b. Expose SSH_AUTH_SOCK to all SSH sessions via ~/.ssh/environment.
#     sshd reads this file for every session (PermitUserEnvironment yes is set
#     in the image). This makes agent forwarding available in non-interactive
#     sessions (e.g., `ssh host bash -s`, VS Code remote, etc.).
if [ -n "${SSH_AUTH_SOCK}" ]; then
    echo "==> Configuring SSH agent forwarding for all sessions..."
    echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}" >> "${DEV_HOME}/.ssh/environment"
    chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh/environment"
    chmod 600 "${DEV_HOME}/.ssh/environment"
fi

# 4. Ensure SSH host keys exist and runtime dirs are set up
echo "==> Generating SSH host keys..."
ssh-keygen -A
mkdir -p /run/sshd

# 5. Start the SSH daemon in the foreground
echo "==> Starting SSH daemon. ICEbox is ready."
/usr/sbin/sshd -D -e