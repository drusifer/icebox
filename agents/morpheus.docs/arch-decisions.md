# ICEBox2 Architecture Decisions

**Last updated:** 2026-06-05

---

## S1 — Session ID
- Format: `openssl rand -hex 3` — 6 hex chars (e.g., `a3f8c2`)
- Pod name: `icebox-<project>-<session-id>`
- Stored in `/var/tmp/icebox/<project>/.session`

## S2 — Pod Sequence
1. `podman pod create --name <pod> --network=pasta [--runtime=runsc] [--userns=auto]`
2. `podman run --pod ... tailscale/tailscale:latest` (TS_USERSPACE=true)
3. Wait for Tailscale Online=true
4. `podman run --pod ... trixie-icebox:latest`
5. Wait for sshd port 22 ready via Tailscale
6. exec `waypipe ssh dev@icebox-<session-id>.<tailnet> foot`

## S3 — Developer Access (Option B: sshd over Tailscale)
- `openssh-server` in image; accessible only via Tailscale WireGuard tunnel
- `sshd_config`: `AllowTcpForwarding no`, `PermitTunnel no`, `AllowAgentForwarding no`
- `waypipe ssh` is the primary access method — opens native Wayland terminal on developer's desktop
- code-server still available at `http://icebox-<session-id>.<tailnet>:8080` as secondary

## S4 — Git PR Flow
- Host `.git` bind-mounted read-only (workspace initialisation only)
- `receive.git` (bare clone of host `.git`) created at session start; bind-mounted writable into sandbox
- Agent pushes branches to `upstream` remote → `receive.git`
- Host fetches from `receive.git` — only host .git hooks execute; container hooks never run on host
- `make pr-list` / `make merge BRANCH=<b>` for host-side review and merge

## S5 — waypipe SSH
- Replaces socat TCP bridge approach
- `waypipe ssh dev@<tailscale-hostname> foot` — waypipe wraps the SSH connection; foot terminal rendered on host Wayland compositor
- Socat and in-container TCP bridge removed from image
- `make auth` auto-execs this after pod is ready; blocks until user exits terminal

## S6 — Secrets
- `TS_AUTHKEY`: env var → `~/.config/icebox/secrets` → clear error with admin console URL
- Session keypair: `ssh-keygen -t ed25519`; `chmod 644` on host (world-readable for container staging)
- Staged at `/icebox/id_session:ro,Z`; entrypoint copies to tmpfs `~/.ssh/id_ed25519` with `chmod 600`
- Host `~/.ssh/` never bind-mounted

## S7 — Container Hardening
- `--network=pasta`: host/LAN unreachable from pod
- `--userns=auto`: container root maps to high host UID; post-breakout process owns nothing (pending TS sidecar live test)
- `--security-opt no-new-privileges`; AppArmor enabled (no `label=disable`)
- `--cap-drop=ALL` + minimal adds (CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID)
- `--read-only` root; all bind-mounts `:ro,Z` by default; `mounts.rw: true` opts in
- `--pids-limit=256`
- gVisor (`--runtime=runsc`) optional; controlled via `ICEBOX_RUNTIME` variable

## S8 — Landlock Wrapper
- Kernel 6.12 provides Landlock ABI v4 (network restrictions available)
- `icebox-run` C binary compiled into image
- Filesystem rules: allow read/write/exec on `/workspace` and `/tmp` only
- Network rules: TCP `connect()` allowed only on ports in `icebox-config.yaml` `egress.ports`
- Restrictions inherited by child processes; cannot be removed after `landlock_restrict_self()`
- Usage: `icebox-run claude`, `icebox-run python script.py`

## S9 — Tests
- No live Tailscale required for dry-run test suite
- Image-dependent tests skip with message if image not built
- Security properties (AppArmor, caps, pids-limit, mount flags, network) verified by grep against Makefile
