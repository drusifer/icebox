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
mkdir -p "${DEV_HOME}/.ssh"
echo "${ICEBOX_SSH_PUB_KEY}" > "${DEV_HOME}/.ssh/authorized_keys"

# Set correct permissions
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh"
chmod 700 "${DEV_HOME}/.ssh"
chmod 600 "${DEV_HOME}/.ssh/authorized_keys"

# 3. Ensure SSH host keys exist and runtime dirs are set up
echo "==> Generating SSH host keys..."
ssh-keygen -A
mkdir -p /run/sshd

# 4. Start the SSH daemon in the foreground
echo "==> Starting SSH daemon. ICEbox is ready."
/usr/sbin/sshd -D -e