FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server curl git sudo \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 dev \
    && useradd -m -u 1000 -g 1000 -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev \
    && echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

# Developer toolchain: Node.js, Python, LLVM/Clang, Go, and AI agent CLIs
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm \
        python3 python3-pip python3-venv \
        clang llvm lld \
        golang-go \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code @google/gemini-cli

# Install VS Code CLI (code)
RUN curl -fsSL "https://update.code.visualstudio.com/latest/cli-linux-arm64/stable" \
        -o /tmp/vscode-cli.tar.gz \
    && tar -xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin \
    && rm /tmp/vscode-cli.tar.gz

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
