# ICEbox Status

## ICEBox2 Sprint — Complete

All phases implemented, tested, and architecture-reviewed.

| Phase | Description | Tests |
|---|---|---|
| Phase 0 | Config schema + repo checkout | ✅ |
| Phase 1 | Dockerfile + entrypoint (baseline) | ✅ |
| Phase 2 | Ephemeral cert delegation | ✅ |
| Phase 3 | Pod lifecycle + session ID + secrets | ✅ |
| Phase 4 | Tailscale sidecar + MagicDNS | ✅ |
| Phase 5 | Container hardening | ✅ |
| Phase 6 | BATS test suite | ✅ |
| Phase 7 | waypipe SSH + foot terminal | ✅ |
| Phase 8 | Git PR flow (receive.git) | ✅ |
| Phase 9 | userns=auto + gVisor runtime | ✅ |
| Phase 10 | Landlock wrapper (icebox-run) | ✅ |
| Phase 11 | Review + docs | ✅ |

**Test suite:** 45/45 pass (7 skip — require `make build` on target host)

---

## What Works (ICEBox2)

- **Ephemeral Podman pod** per session: sidecar + sandbox in shared network namespace
- **Tailscale ingress** (inverted — no inbound ports on host): `http://icebox-<session>.<tailnet>:8080`
- **waypipe + sshd terminal**: `make auth` opens a Wayland foot terminal forwarded over Tailscale SSH
- **code-server** on port 8080 inside pod, accessible via MagicDNS
- **Session keypair**: ephemeral ed25519 per session; separate from developer's own key
- **Git PR flow**: agent pushes to `upstream` (receive.git); developer reviews with `make pr-list` / `make merge`
- **Security layers**: read-only root FS, cap-drop=ALL, no-new-privileges, --pids-limit=256, AppArmor re-enabled, pasta network (host/LAN unreachable), userns=auto, gVisor (optional), Landlock (icebox-run)
- **icebox-config.yaml**: per-project config for credentials, extra repos, extra mounts, egress ports

---

## Backlog (out of scope this sprint)

- L7 Egress Proxy (Squid WAF — domain-level allowlist, complements Landlock port allowlist)
- `ICEBOX_ALLOW_NETWORKS` opt-in LAN access flag
- Pi-hole filtered DNS group for containers
- Vault/PKI derived session certificates for mTLS
- Landlock v5 hardening (symlink + ioctl restrictions)

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image: Debian Trixie + sshd + code-server + foot + Landlock wrapper |
| `Icebox.mk` | Pod lifecycle: auth, connect, status, down, clean, pr-list, merge |
| `entrypoint.sh` | Container init: sshd as PID 1, code-server background, git workspace |
| `sshd_config` | Locked-down sshd: pubkey only, no forwarding/tunnel/agent/X11 |
| `icebox-run.c` | Landlock ABI v4 sandbox wrapper (compiled into image at build time) |
| `icebox-config.yaml` | Example project config (credentials, repos, mounts, egress.ports) |
| `test_icebox.bats` | BATS test suite: 45 tests covering all phases |
| `docs/ICEBox2.md` | Architecture spec (Tailscale ephemeral sidecar design) |
| `task.md` | Sprint task board |
