# ICEbox Status

## What Works (Milestone 1 Complete)

- **Container boots and SSH works** on Raspberry Pi (arm64/Debian Trixie)
- **Image**: `mcr.microsoft.com/devcontainers/base:trixie` + openssh-server + curl, built locally via `make build`
- **Makefile lifecycle**: `make build`, `make up`, `make down`, `make clean`
- **Three operational modes**: `standard`, `zero_leakage`, `resource_saver` with correct mount strategies
- **Security posture**: read-only root, `no-new-privileges`, `cap-drop=ALL` + minimal caps for sshd (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `NET_BIND_SERVICE`, `SYS_CHROOT`, `SETUID`, `SETGID`)
- **SSH access**: auto-detects public key, injects into container, pubkey auth verified working
- **Filesystem**: tmpfs at `/workspace`, `/home/vscode`, `/run`, `/tmp`; disk-backed `.cache`
- **Git workspace restoration**: host `.git` mounted read-only at `/icebox/.git`, active branch checked out into `/workspace` on startup as `DEV_USER`
- **Entrypoint permissions**: `entrypoint.sh` is executable in git, no workaround needed
- **Test framework**: bats test suite with bats-support/bats-assert submodules

## Backlog

- **Network security / URL filtering** — restrict LAN access by default, allow opt-in via env var. Requires Squid proxy + SSL bump; deferred to a separate milestone.
- **K3s cluster (Milestone 2)** — Ansible + Helm setup exists in `cluster/` but is untested

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image definition: trixie base + openssh-server + curl |
| `Makefile` | Container lifecycle, image build, mode selection, podman orchestration |
| `entrypoint.sh` | Container init: SSH setup, git workspace restore, host key gen, start sshd |
| `test_icebox.bats` | Bats test suite covering all modes and lifecycle |
| `REQUIREMENTS.md` | Full product requirements |
| `implementation_plan.md` | Implementation plan and backlog |
| `cluster/` | K3s Ansible/Helm setup (Milestone 2, untracked) |
