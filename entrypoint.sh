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

# Start waypipe server wrapping code-server, then expose its Unix socket over TCP via socat.
# waypipe only supports Unix sockets; socat bridges TCP 7681 → /tmp/waypipe-server.sock
# so `make connect` on the host can tunnel in over Tailscale.
echo "==> Starting code-server via waypipe. ICEbox is ready."
su -s /bin/bash "${DEV_USER}" -c \
    "waypipe --socket /tmp/waypipe-server.sock server -- code-server --bind-addr 127.0.0.1:8080 /workspace" &
# Wait for waypipe socket to appear before accepting connections
for i in $(seq 1 10); do
    [ -S /tmp/waypipe-server.sock ] && break
    sleep 1
done
exec socat TCP-LISTEN:7681,reuseaddr,fork UNIX-CONNECT:/tmp/waypipe-server.sock
