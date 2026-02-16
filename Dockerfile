FROM mcr.microsoft.com/devcontainers/base:trixie
RUN apt-get update && apt-get install -y openssh-server curl && rm -rf /var/lib/apt/lists/*
