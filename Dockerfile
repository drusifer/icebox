FROM mcr.microsoft.com/devcontainers/base:trixie
RUN apt-get update && apt-get install -y openssh-server curl && rm -rf /var/lib/apt/lists/*
# Rename the default dev user from 'vscode' to 'iceman'
RUN usermod -l iceman vscode \
 && groupmod -n iceman vscode \
 && usermod -d /home/iceman -m iceman \
 && sed -i 's/vscode/iceman/g' /etc/sudoers.d/90-cloud-init-users 2>/dev/null || true
# Allow sshd to read per-user environment files (~/.ssh/environment).
# Used to expose SSH_AUTH_SOCK (agent forwarding) to all SSH sessions.
RUN echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
