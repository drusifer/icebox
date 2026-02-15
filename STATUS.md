# ICEbox Status

## What Works

- **Container boots and SSH works** on Raspberry Pi (arm64/Debian Trixie)
- **Image**: `mcr.microsoft.com/devcontainers/base:trixie` + openssh-server, built locally via `make build`
- **Makefile lifecycle**: `make build`, `make up`, `make down`, `make clean`
- **Three operational modes**: `standard`, `zero_leakage`, `resource_saver` with correct mount strategies
- **Security posture**: read-only root, `no-new-privileges`, `cap-drop=ALL` + minimal caps for sshd (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `NET_BIND_SERVICE`, `SYS_CHROOT`, `SETUID`, `SETGID`)
- **SSH access**: auto-detects public key, injects into container, pubkey auth verified working
- **Filesystem**: tmpfs at `/workspace`, `/home/vscode`, `/run`, `/tmp`; disk-backed `.cache`
- **Test framework**: bats test suite with bats-support/bats-assert submodules

## What Needs Fixing (before tests pass)

- **`entrypoint.sh` not executable** — Makefile has a `chmod +x` workaround. Should be set executable in git.
- **Output messages don't match tests** — tests assert specific strings like `"==> Cleaning up container and all artifacts"` that the Makefile doesn't currently print.
- **Tests need updating** — tests reference old image, assume `.git` mount, and don't account for the `build` step.

## Backlog

- **Git workspace restoration** — mount host `.git` read-only, checkout active branch into volatile `/workspace` on startup as `DEV_USER`
- **Network security (`ICEBOX_ALLOW_NETWORKS`)** — restrict LAN access by default, allow opt-in via env var
- **K3s cluster (Milestone 2)** — Ansible + Helm setup exists in `cluster/` but is untested

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image definition: trixie base + openssh-server |
| `Makefile` | Container lifecycle, image build, mode selection, podman orchestration |
| `entrypoint.sh` | Container init: SSH setup, host dir ownership, host key gen, start sshd |
| `test_icebox.bats` | Bats test suite covering all modes and lifecycle |
| `REQUIREMENTS.md` | Full product requirements |
| `implementation_plan.md` | Implementation plan and backlog |
| `cluster/` | K3s Ansible/Helm setup (Milestone 2, untracked) |
