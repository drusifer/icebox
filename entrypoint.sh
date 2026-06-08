#!/bin/bash
set -e

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"

echo "==> ICEbox entrypoint started."

if ! id -u "${DEV_USER}" >/dev/null 2>&1; then
    echo "Error: User '${DEV_USER}' not found in container image."
    exit 1
fi

chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"

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
    su -s /bin/bash "${DEV_USER}" -c "
        set -e
        cd /workspace
        git init
        git config --global safe.directory /icebox/.git
        git config --global core.hooksPath /dev/null
        git remote add origin /icebox/.git
        git fetch origin
        git checkout '${BRANCH}'
        if [ -d '/icebox/receive.git' ]; then
            git remote add upstream /icebox/receive.git
            echo '==> upstream remote → /icebox/receive.git (push branches here for review)'
        fi
        echo 'cd /workspace' >> '${DEV_HOME}/.bashrc'
    "
    echo "==> Git workspace restored (branch: ${BRANCH})."
fi

# Clone additional repos from config (bind-mounted host bare clones)
for repo_mount in /icebox/repos/*/; do
    [ -d "${repo_mount}" ] || continue
    repo_name=$(basename "${repo_mount}")
    if [ ! -d "/workspace/${repo_name}" ]; then
        echo "==> Cloning repo ${repo_name}..."
        su -s /bin/bash "${DEV_USER}" -c "git clone '${repo_mount}' '/workspace/${repo_name}'"
    fi
done

# Generate SSH host keys, start code-server in background, exec sshd as PID 1.
echo "==> Starting services..."
mkdir -p /run/user/1000
chown "${DEV_USER}:${DEV_USER}" /run/user/1000
chmod 700 /run/user/1000
chmod 1777 /tmp
ssh-keygen -A -q
su -s /bin/bash "${DEV_USER}" -c \
    "code-server --bind-addr 127.0.0.1:8080 /workspace > /tmp/code-server.log 2>&1" &
echo "==> ICEbox ready."
exec /usr/sbin/sshd -D -e
