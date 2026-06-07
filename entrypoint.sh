#!/bin/bash
set -e

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"

echo "==> ICEbox entrypoint started."

if ! id -u "${DEV_USER}" >/dev/null 2>&1; then
    echo "Error: User '${DEV_USER}' not found in container image."
    exit 1
fi

# Copy session keypair from read-only staging mount into tmpfs ~/.ssh.
# The source at /icebox/id_session is ro — we cannot chmod it directly.
# Copying to tmpfs gives us a writable copy we can lock down to 600.
if [ -f "/icebox/id_session" ]; then
    mkdir -p "${DEV_HOME}/.ssh"
    cp /icebox/id_session "${DEV_HOME}/.ssh/id_ed25519"
    chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh"
    chmod 700 "${DEV_HOME}/.ssh"
    chmod 600 "${DEV_HOME}/.ssh/id_ed25519"
fi

# Inject developer's SSH public key into authorized_keys so they can
# log in via waypipe ssh over Tailscale.
if [ -f "/icebox/dev.pub" ]; then
    mkdir -p "${DEV_HOME}/.ssh"
    cat /icebox/dev.pub >> "${DEV_HOME}/.ssh/authorized_keys"
    chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh"
    chmod 700 "${DEV_HOME}/.ssh"
    chmod 600 "${DEV_HOME}/.ssh/authorized_keys"
fi

# Restore git workspace from bind-mounted host .git
if [ -d "/icebox/.git" ]; then
    echo "==> Restoring git workspace..."
    BRANCH="${ICEBOX_GIT_BRANCH:-main}"
    if [ -z "${ICEBOX_GIT_BRANCH}" ] && [ -f "/icebox/.git/HEAD" ]; then
        HEAD_CONTENT=$(cat /icebox/.git/HEAD)
        if echo "${HEAD_CONTENT}" | grep -q "^ref: refs/heads/"; then
            BRANCH=$(echo "${HEAD_CONTENT}" | sed 's|^ref: refs/heads/||')
        else
            BRANCH="${HEAD_CONTENT}"
        fi
    fi
    chown "${DEV_USER}:${DEV_USER}" /workspace
    cd /workspace
    git init
    git config --global safe.directory /icebox/.git
    # Disable hook execution — hooks in the mounted .git must never run on the host
    git config --global core.hooksPath /dev/null
    git remote add origin /icebox/.git
    git fetch origin
    git checkout "${BRANCH}"
    if [ -d "/icebox/receive.git" ]; then
        git remote add upstream /icebox/receive.git
        echo "==> upstream remote → /icebox/receive.git (push branches here for review)"
    fi
    echo "cd /workspace" >> "${DEV_HOME}/.bashrc"
    echo "==> Git workspace restored (branch: ${BRANCH})."
fi

# Clone additional repos from config (bind-mounted host bare clones)
for repo_mount in /icebox/repos/*/; do
    [ -d "${repo_mount}" ] || continue
    repo_name=$(basename "${repo_mount}")
    if [ ! -d "/workspace/${repo_name}" ]; then
        echo "==> Cloning repo ${repo_name}..."
        git clone "${repo_mount}" "/workspace/${repo_name}"
    fi
done

# Generate SSH host keys, start code-server in background, exec sshd as PID 1.
echo "==> Starting services..."
ssh-keygen -A -q
su -s /bin/bash "${DEV_USER}" -c \
    "code-server --bind-addr 127.0.0.1:8080 /workspace > /tmp/code-server.log 2>&1" &
echo "==> ICEbox ready."
exec /usr/sbin/sshd -D -e
