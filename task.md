# ICEBox2 Sprint — Task Board

**Sprint:** ICEBox2 — Tailscale Ephemeral Sidecar
**Start:** 2026-06-04
**Goal:** Heavily sandboxed ephemeral dev enclave. Agent runs inside Landlock + gVisor + userns-isolated pod. Developer accesses via waypipe Wayland terminal over Tailscale. Agent PRs to host via bare receive repo; host merges and pushes upstream.

---

## ✅ Phase 0 — Config Schema + Repo Checkout
*`icebox-config.yaml` parsing and host-side repo management.*

- [x] **T0.1** Define and document `icebox-config.yaml` schema (credentials + repos + mounts)
- [x] **T0.2** Add `icebox-config.yaml` parser to Makefile (python3 yaml)
- [x] **T0.3** Repo checkout logic in `make auth`: clone bare to host cache if missing
- [x] **T0.4** Current project auto-included via .git bind-mount
- [x] **T0.5** Fail with clear error if config missing or malformed
- [x] **T0.6** Example `icebox-config.yaml` in repo
- [x] **T0.7** Config parsed correctly, repos cloned on first `make auth` — tests pass

---

## ✅ Phase 1 — Dockerfile + Entrypoint (baseline image)
*Remove SSH (initial), add code-server + waypipe + socat. Note: SSH returns in Phase 7 (Option B).*

- [x] **T1.1** Remove `openssh-server` from Dockerfile *(reverted in Phase 7)*
- [x] **T1.2** Install `code-server` release binary for arm64 (.deb, not npm)
- [x] **T1.3** Install `waypipe` + `socat` packages *(socat removed in Phase 7)*
- [x] **T1.4** `entrypoint.sh`: waypipe server + socat TCP bridge as PID 1 *(replaced in Phase 7)*
- [x] **T1.5** `entrypoint.sh`: clone repos from bind-mounted host bare clones
- [x] **T1.6** Drop `NET_BIND_SERVICE` and `SYS_CHROOT` from cap list
- [x] **T1.7** `make build` succeeds; code-server + waypipe start — image tests pass (skip pending build)

---

## ✅ Phase 2 — Ephemeral Cert Delegation
*Per-session keypair generation, staging mount, cleanup on teardown.*

- [x] **T2.1** Session keypair generated: `ssh-keygen -t ed25519 -f .../id_session -N ""`
- [x] **T2.2** `chmod 644` on host key so container can read from staging mount
- [x] **T2.3** Key staged at `/icebox/id_session:ro,Z`; entrypoint copies to tmpfs `~/.ssh` with `chmod 600`
- [x] **T2.4** Session keypair deleted on `make down` / `make clean`
- [x] **T2.5** Host `~/.ssh/` never bind-mounted into pod — test passes
- [x] **T2.6** Session cert present in pod; host root keys absent — test passes

---

## ✅ Phase 3 — Pod Lifecycle + Session ID + Secrets
*Podman pod model, session ID, TS_AUTHKEY loading, `make auth` orchestration.*

- [x] **T3.1** Session ID: `openssl rand -hex 3`; persisted to `/var/tmp/icebox/<project>/.session`
- [x] **T3.2** `podman pod create` + `podman run --pod` for sidecar + sandbox
- [x] **T3.3** `TS_AUTHKEY`: env var → `~/.config/icebox/secrets` → clear error with admin URL
- [x] **T3.4** `down` / `clean` use `podman pod rm -f`; delete session keypair
- [x] **T3.5** `make status`: list running icebox pods and MagicDNS URLs
- [x] **T3.6** `make auth` is the single entry point

---

## ✅ Phase 4 — Tailscale Sidecar + MagicDNS
*TS_USERSPACE=true, health checks, URL output.*

- [x] **T4.1** Tailscale sidecar: `TS_USERSPACE=true`, `TS_HOSTNAME=icebox-<session-id>`, `TS_AUTHKEY`
- [x] **T4.2** Tailscale readiness: poll `tailscale status --json` until `Online:true`
- [x] **T4.3** code-server health check: poll `curl -sf http://127.0.0.1:8080`
- [x] **T4.4** Print on startup: `http://icebox-<session-id>.<tailnet>:8080`

---

## ✅ Phase 5 — Container Hardening (security pass)
*Network isolation, filesystem lockdown, capability minimisation.*

- [x] **T5.1** `--network=pasta` on pod: host/LAN unreachable from container
- [x] **T5.2** `.git` bind-mount changed to `:ro,Z`; `receive.denyCurrentBranch` write removed
- [x] **T5.3** `core.hooksPath /dev/null` in entrypoint: no hook execution even on cloned workspace
- [x] **T5.4** `mounts:` section in config: all extra bind-mounts `:ro,Z` by default; `rw: true` opts in
- [x] **T5.5** Missing host path in `mounts:` → hard error at pod start
- [x] **T5.6** `label=disable` removed: AppArmor profile re-enabled on sandbox
- [x] **T5.7** `SYS_CHROOT` dropped from cap-add list
- [x] **T5.8** `--pids-limit=256` on sandbox container

---

## ✅ Phase 6 — BATS Test Suite
*25 tests; 22 pass dry-run, 3 skip pending image build.*

- [x] **T6.1** SSH-specific tests removed
- [x] **T6.2** Pod lifecycle, session ID, teardown cleanup tests
- [x] **T6.3** Missing `TS_AUTHKEY` → clear error
- [x] **T6.4** Missing / malformed `icebox-config.yaml` → clear error
- [x] **T6.5** Ephemeral keypair generated; absent from `~/.ssh/`
- [x] **T6.6** `make status` output format
- [x] **T6.7** AppArmor, SYS_CHROOT, pids-limit, key staging path verified by grep tests
- [x] **T6.8** REPO_MOUNTS and EXTRA_MOUNTS Python quoting verified
- [x] **T6.9** `make test` passes on darius (arm64)

---

## Phase 7 — waypipe SSH + Terminal (replace socat) — `neo`
*Swap socat TCP bridge for `waypipe ssh`. Add sshd (Option B, Tailscale-only). `make auth` opens terminal directly.*

- [ ] **T7.1** Add `openssh-server` back to Dockerfile
- [ ] **T7.2** Add locked-down `sshd_config`: `AllowTcpForwarding no`, `PermitTunnel no`, `AllowAgentForwarding no`, `X11Forwarding no`
- [ ] **T7.3** Add `foot` terminal emulator to Dockerfile
- [ ] **T7.4** Remove `socat` from Dockerfile
- [ ] **T7.5** Rewrite `entrypoint.sh`: start sshd + code-server (background); waypipe server gone
- [ ] **T7.6** Inject developer's SSH public key into `authorized_keys` (from `credentials[0]` public key or first `~/.ssh/id_*.pub`)
- [ ] **T7.7** `make auth`: after sshd ready, exec `waypipe ssh dev@icebox-<session-id>.<tailnet> foot` — blocks until user exits terminal
- [ ] **T7.8** `make connect` simplified: `waypipe ssh dev@icebox-<session-id>.<tailnet> foot` (re-attach after detach)
- [ ] **T7.9** Remove socat bridge from `make connect`
- [ ] **T7.10** sshd readiness wait: poll `ssh -o ConnectTimeout=1 ... true` until success
- [ ] **T7.11** BATS: sshd present in image; socat absent; `foot` present — `trin`

---

## Phase 8 — Git PR Flow (receive.git) — `neo`
*Bare receive repo as safe intermediary for agent → host branch pushes.*

- [ ] **T8.1** `make auth`: `git clone --bare <host .git> /var/tmp/icebox/<project>/receive.git`
- [ ] **T8.2** Bind-mount `receive.git` into sandbox at `/icebox/receive.git:Z` (writable)
- [ ] **T8.3** `entrypoint.sh`: configure `upstream` remote → `/icebox/receive.git`
- [ ] **T8.4** `make pr-list`: `git -C receive.git branch -a` — list branches agent has pushed
- [ ] **T8.5** `make merge BRANCH=<b>`: `git fetch receive.git <b>:<b>` + `git merge --no-ff <b>` on host
- [ ] **T8.6** `make clean`: remove `receive.git` with rest of session artifacts
- [ ] **T8.7** BATS: receive.git created on `make auth`; agent push lands in receive.git; host fetch works — `trin`

---

## Phase 9 — userns=auto + gVisor — `neo`
*User namespace remapping and optional gVisor runtime.*

- [ ] **T9.1** Add `--userns=auto` to `podman pod create`; verify Tailscale sidecar still connects (live test on darius)
- [ ] **T9.2** Verify session keypair readable by container with userns=auto (chmod 644 already in place)
- [ ] **T9.3** Check gVisor availability on darius: `podman run --runtime=runsc ...`; add `ICEBOX_RUNTIME ?= runc` variable to Makefile
- [ ] **T9.4** If gVisor available: `podman pod create --runtime=$(ICEBOX_RUNTIME)`; default stays `runc`
- [ ] **T9.5** Document gVisor install steps for darius in `README.md`
- [ ] **T9.6** BATS: userns=auto present in pod create; runtime variable respected — `trin`

---

## Phase 10 — Landlock Wrapper (`icebox-run`) — `neo`
*Per-agent filesystem + network restrictions. Egress deny-by-default driven from config.*

- [ ] **T10.1** Add `egress.ports` section to `icebox-config.yaml` schema (list of allowed TCP ports)
- [ ] **T10.2** Write `icebox-run.c`: Landlock ABI v4 wrapper — fs restrict to `/workspace` + `/tmp`; net restrict to `egress.ports` from config
- [ ] **T10.3** Add `gcc`, `liblandlock-dev` (or inline syscall wrappers) to Dockerfile build stage; compile `icebox-run` into image
- [ ] **T10.4** Mount `icebox-config.yaml` as `/icebox/config.yaml:ro,Z` in sandbox so `icebox-run` can read it
- [ ] **T10.5** Document `icebox-run <cmd>` usage in `foot` terminal MOTD / README
- [ ] **T10.6** BATS: `icebox-run` binary present in image; filesystem restriction verified (attempt to read `/etc/passwd` → denied); network restriction verified — `trin`

---

## Phase 11 — Review + Docs — `morpheus` / `neo`
*Code review, README, USER_GUIDE, REQUIREMENTS.*

- [ ] **T11.1** Morpheus reviews phases 7–10 for architecture compliance
- [ ] **T11.2** Update `README.md`: prerequisites (`waypipe`, `foot` on host), `make auth` quickstart, `make pr-list` / `make merge` workflow
- [ ] **T11.3** Update `USER_GUIDE.md`: replace SSH workflow with waypipe terminal flow; document agent PR workflow; document `icebox-run` usage
- [ ] **T11.4** Update `REQUIREMENTS.md` and `STATUS.md` to reflect ICEBox2 completion

---

## Backlog (out of scope this sprint)
- L7 Egress Proxy (Squid WAF — domain-level allowlist, complements Landlock port allowlist)
- `ICEBOX_ALLOW_NETWORKS` opt-in LAN access flag
- Pi-hole filtered DNS group for containers
- Vault/PKI derived session certificates for mTLS
- Landlock ABI v3 hardening (symlink + ioctl restrictions — already on kernel 6.12)

---
*Last updated: 2026-06-05*
