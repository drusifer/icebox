#!/bin/bash
set -e

# This script is the entrypoint for the ICEbox container.
# It performs final setup steps before starting the SSH server.

DEV_USER="${DEV_USER:-vscode}" # Default to 'vscode' if not set
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
    chown "${DEV_USER}:${DEV_USER}" /workspace
    su - "${DEV_USER}" -s /bin/bash -c "
        cd /workspace
        git init
        git remote add origin /icebox/.git
        git fetch origin
        git checkout ${ICEBOX_GIT_BRANCH:-main}
    "
    # Set GIT_DIR and GIT_WORK_TREE in DEV_USER's shell profile
    echo "export GIT_DIR=/workspace/.git" >> "${DEV_HOME}/.bashrc"
    echo "export GIT_WORK_TREE=/workspace" >> "${DEV_HOME}/.bashrc"
    echo "cd /workspace" >> "${DEV_HOME}/.bashrc"
    echo "==> Git workspace restored (branch: ${ICEBOX_GIT_BRANCH:-main})."
fi

# 4. Ensure SSH host keys exist and runtime dirs are set up
echo "==> Generating SSH host keys..."
ssh-keygen -A
mkdir -p /run/sshd

# 5. Start the SSH daemon in the foreground
echo "==> Starting SSH daemon. ICEbox is ready."
/usr/sbin/sshd -D -e