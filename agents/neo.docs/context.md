## Recent Decisions

- waypipe is now host-only (removed from image); foot runs inside container, display forwarded via waypipe
- sshd readiness uses `podman exec pgrep -x sshd` (simpler than SSH polling — Tailscale routing may not be instant when sshd starts)
- `make auth` now blocks (execs waypipe ssh foot) — intentional; user exits terminal to end session
- `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null` on waypipe ssh — ephemeral host keys each session
- Developer public key (SSH_KEY_PATH) staged as dev.pub, separate from session keypair (id_session used by agent for git)
- sshd runs as root (exec sshd -D -e as PID 1), so NET_BIND_SERVICE not needed; SYS_CHROOT not added back

## Key Findings

- **Two BATS tests were inverted** from Phase 1: waypipe (was in image, now not) and sshd (was absent, now present)
- **code-server health check removed** from _start_sandbox — sshd readiness is now the gate
- Image tests (23-27) skip without a built image — `make build` required on darius to fully verify

## Important Notes
- Phase 8 (receive.git) is COMPLETE — 33/33 tests pass
- Phase 9 (userns=auto), Phase 10 (Landlock) are NOT yet implemented
- `make auth` header comment in Icebox.mk still says "print MagicDNS URL" — update in Phase 11 docs pass

## Phase 8 Design Decisions
- receive.git is bare-cloned from CURDIR/.git in `_session_start` (before pod creation)
- Mounted `:Z` (writable, no `ro`) so agent can push branches into it
- `make clean` removes it via `rm -rf $(SESSION_DIR)` — no explicit removal needed in `down`
- `upstream` remote in entrypoint.sh is conditional on `/icebox/receive.git` existing (safe fallback)

## Phase 9 Design Decisions
- `--userns=auto` on `podman pod create` (pod-level); `--userns=keep-id` removed from sandbox run
- With `--userns=auto`: container root (UID 0) → host non-root UID; bind-mounted files must be world-readable (644) — already the case for id_session, dev.pub
- `ICEBOX_RUNTIME ?= runc` — override with `ICEBOX_RUNTIME=runsc` for gVisor
- Live Tailscale+sshd verify with userns=auto must be done on darius — cannot dry-run in BATS

---
*Last updated: 2026-06-06*
