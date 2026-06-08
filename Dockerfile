FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl git sudo openssh-server foot waypipe \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 dev \
    && useradd -m -u 1000 -g 1000 -s /bin/bash dev \
    && usermod -p '*' dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# Developer toolchain: Node.js, Python, LLVM/Clang, Go, and AI agent CLIs
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm \
        python3 python3-pip python3-venv \
        clang llvm lld \
        golang-go \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code @google/gemini-cli

# Install code-server (arm64 native binary from cdr/code-server releases)
RUN CODE_SERVER_VERSION="$(curl -fsSL https://api.github.com/repos/coder/code-server/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')" \
    && curl -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_arm64.deb" \
        -o /tmp/code-server.deb \
    && dpkg -i /tmp/code-server.deb \
    && rm /tmp/code-server.deb

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Compile icebox-run Landlock wrapper (clang from toolchain layer; no extra packages needed)
COPY icebox-run.c /tmp/icebox-run.c
RUN clang -O2 -o /usr/local/bin/icebox-run /tmp/icebox-run.c && rm /tmp/icebox-run.c

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
