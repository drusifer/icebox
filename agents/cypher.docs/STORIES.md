# ICEBox2 Sprint Stories

**Epic:** ICEBox2 — Tailscale Ephemeral Sidecar
**Author:** Cypher
**Date:** 2026-06-04 (updated with feedback)
**Baseline:** Existing system has working SSH access, three modes, git write-back (Option A), read-only rootfs, BATS tests.
**Delta:** Replace SSH ingress with Tailscale sidecar pod. Replace sshd with code-server + waypipe. Add config-driven credential delegation, multi-repo checkout, turnkey `make auth`.

---

## Story 1 — Podman Pod Lifecycle (replaces single-container model)

**As a developer,** I want `make icebox` to provision a named Podman *pod* with a unique session ID, so that multiple containers share a network namespace and I can run multiple isolated sessions simultaneously.

**Acceptance Criteria:**
- `make icebox` creates a pod named `icebox-<project>-<session-id>` (session ID = `openssl rand -hex 3`, e.g. `a3f8k2`)
- Session ID persisted to `/var/tmp/icebox/<project>/.session` for lifecycle commands
- `make down` / `make clean` destroys pod with `podman pod rm -f`
- Existing running session: `make icebox` prints URL instead of starting a new one
- `make status` lists all running icebox pods with session IDs and MagicDNS URLs

---

## Story 2 — Tailscale Sidecar Container

**As a developer,** I want the pod to include a Tailscale sidecar so the sandbox is reachable from my Tailnet via MagicDNS with no host ports exposed.

**Acceptance Criteria:**
- Pod contains `tailscale/tailscale:latest` as the first container
- `TS_USERSPACE=true` (no NET_ADMIN required)
- `TS_HOSTNAME=icebox-<session-id>`, `TS_AUTHKEY` passed from `make auth` secrets resolution
- On pod teardown, ephemeral key auto-purges node from Tailnet — zero ghost records
- Tailscale readiness check before sandbox container starts

---

## Story 3 — code-server on Port 8080 (replaces sshd)

**As a developer,** I want the sandbox to serve VS Code via `code-server` on `127.0.0.1:8080` so I can access a browser-based IDE through the Tailscale sidecar with no SSH daemon in the pod.

**Acceptance Criteria:**
- `code-server` release binary (arm64) installed in Dockerfile — not npm
- Entrypoint starts code-server bound to `127.0.0.1:8080`, opened to `/workspace`, running as `dev`
- `openssh-server` removed from Dockerfile; `NET_BIND_SERVICE` cap dropped from Makefile
- `ssh-config` Makefile target replaced with MagicDNS URL display
- Old SSH-based workflow explicitly documented as replaced in USER_GUIDE.md

---

## Story 4 — `make auth` Turnkey Startup

**As a developer,** I want a single `make auth` command that handles all session provisioning end-to-end — credentials, repos, pod, and access — so I can go from zero to working environment without manual steps.

**Acceptance Criteria:**
- `make auth` sequence:
  1. Parse `icebox-config.yaml` for credential names and repo list
  2. Ensure repos are checked out on host (clone if missing)
  3. Generate ephemeral keypair for the session
  4. Resolve `TS_AUTHKEY` (env → `~/.config/icebox/secrets` → fail with instructions)
  5. Start pod (Tailscale sidecar + sandbox)
  6. Wait for pod healthy
  7. Print MagicDNS URL: `ICEbox ready: http://icebox-<session-id>.<tailnet>:8080`
- Missing `TS_AUTHKEY` → clear error with link to Tailscale admin console
- Missing credential file → clear error naming which cert is missing

---

## Story 5 — waypipe Display Forwarding (raw TCP over Tailscale)

**As a developer,** I want `make connect` to set up a waypipe tunnel to the sandbox's Wayland display over the Tailscale connection, so GUI apps (Kitty, full VS Code) run inside the icebox and cannot exploit my local compositor or host filesystem. No SSH access is granted.

**Acceptance Criteria:**
- waypipe server runs inside sandbox on TCP port 7681 (no SSH — raw TCP transport)
- `make connect` runs `waypipe client connect icebox-<session-id>:7681` on the host
- No SSH daemon, no `ForceCommand` — waypipe uses its native TCP mode through Tailscale tunnel
- `make connect` reads session ID from `/var/tmp/icebox/<project>/.session`
- waypipe listed as host prerequisite in `make help` and README
- Display forwarding tested: Kitty running inside pod renders on host Wayland compositor

---

## Story 6 — Ephemeral Certificate Delegation

**As a developer,** I want the pod to receive only short-lived derived credentials (not my root keys), so a compromised agent inside the pod cannot access my personal SSH keys or propagate to other systems.

**Acceptance Criteria:**
- `icebox-config.yaml` lists credential names only (e.g. `github-deploy`) — no key material
- `make auth` generates a fresh ephemeral ed25519 keypair per session in a temp dir
- Root key referenced by credential name is used to sign/derive the temp cert (or public key registered at needed destination)
- Temp private key bind-mounted read-only into pod at `/home/dev/.ssh/`
- Temp keypair is deleted from host on `make down` / `make clean`
- Host root keys (`~/.ssh/`) are never bind-mounted or copied into the pod

---

## Story 7 — `icebox-config.yaml` Schema

**As a developer,** I want a project-scoped `icebox-config.yaml` in my project root that declares all session configuration — repos and credentials — so the environment is fully reproducible from config alone.

**Acceptance Criteria:**
- `icebox-config.yaml` is project-scoped (lives in project root, committed to repo)
- Schema:
  ```yaml
  credentials:
    - name: github-deploy       # resolves to ~/.ssh/github-deploy
    - name: api-signing-cert    # resolves to ~/.ssh/api-signing-cert

  repos:
    # current project is implicit — always included automatically
    - url: https://github.com/user/shared-lib
      path: ~/projects/shared-lib   # optional local path override
    - url: https://github.com/user/other-dep
  ```
- Current project repo is always added to the repo list automatically (no explicit entry needed)
- `make auth` fails with clear error if `icebox-config.yaml` is missing or malformed
- Example config included in repo

---

## Story 8 — Two-Level Git Checkout Model

**As a developer,** I want repos checked out on my host machine to serve as the origin for pod workspaces, so commits flow pod → host local clone → GitHub (the last step only outside the pod), keeping GitHub push capability off the pod entirely.

**Acceptance Criteria:**
- `make auth` ensures each repo in config is checked out on host (clones if missing, skips if exists)
- Host checkouts bind-mounted as read-only `.git` references into the pod (existing model, extended to multiple repos)
- Pod workspaces cloned from host checkout at startup: pod's `origin` = host local path
- Pod can `git push origin HEAD:<branch>` → updates host local clone refs only
- Pod has no route to GitHub or any remote git host (enforced by network policy)
- `make pull` (or per-repo variant) syncs host working tree after pod pushes — documented in USER_GUIDE.md

---

## Story 9 — BATS Test Suite Update

**As a developer,** I want the BATS test suite updated for the new pod model, config parsing, and cert delegation, so regressions are caught automatically without requiring a live Tailscale connection.

**Acceptance Criteria:**
- SSH-specific tests removed
- New tests: pod lifecycle, session ID file, TS_AUTHKEY missing error, config.yaml parse error
- New tests: ephemeral keypair generated and cleaned up on teardown
- New tests: repo checkout triggered by `make auth` for listed repos
- `make test` passes on darius (arm64); no live Tailscale required

---

## Out of Scope (Backlog)

- L7 Egress Proxy (Squid WAF with dstdomain allowlist) — ICEBox2.md Section 6
- Landlock kernel sandbox — ICEBox2.md Section 6
- `ICEBOX_ALLOW_NETWORKS` opt-in LAN access — PLAN.md Q5
- Pi-hole filtered DNS group for containers — PLAN.md Q3

---
*Last updated: 2026-06-04*
