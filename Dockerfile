FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server curl git sudo \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 dev \
    && useradd -m -u 1000 -g 1000 -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev \
    && echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
