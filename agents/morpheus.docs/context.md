# Morpheus Context

## Recent Decisions

### ADR-001: ICEBox2 — Tailscale Ephemeral Sidecar (2026-06-04)

**Status:** LOCKED (replaces previous Anthos cloud plan — DISCARDED)

**Problem:** Developers need frontier AI model access but agents are potentially compromised. Need strong isolation to protect local resources (homelab, creds, network) without cloud dependency or full orchestration overhead.

**Decision:** Local Podman pod on darius with Tailscale ephemeral sidecar (Inverted Ingress pattern). No cloud, no Kubernetes, no Terraform. Simple bash orchestration script.

#### Architecture

```
darius (host — local hardware, no inbound ports)
└── Podman Pod: icebox-<session-id>  (shared network namespace)
      ├── Container A: tailscale/tailscale:latest  (sidecar)
      │     ├── TS_USERSPACE=true  (no NET_ADMIN needed)
      │     ├── TS_AUTHKEY=<ephemeral key>
      │     └── registers as icebox-<session-id> on Tailnet
      └── Container B: trixie-icebox:latest  (agent sandbox)
            ├── listens on 127.0.0.1:8080  (no host binding)
            └── egress: standard NAT through host, bypasses Tailnet
```

#### Traffic Flow (Inverted Ingress)
- **Ingress:** Developer → `http://icebox-<session-id>:8080` → MagicDNS → WireGuard tunnel → Tailscale sidecar → forwards to 127.0.0.1:8080
- **Egress:** Sandbox → internet via host NAT (not through Tailnet)

#### Session Lifecycle
- **Provision:** bash script generates session ID, starts Podman pod
- **Register:** Tailscale sidecar authenticates with ephemeral key, registers hostname
- **Access:** Developer hits `http://icebox-<session-id>:8080` via MagicDNS
- **Teardown:** `podman pod rm -f <pod-name>` — violently kills network namespace
- **Sanitize:** Ephemeral auth key auto-purges node from Tailnet — zero ghost records

#### Security Posture
| Threat | Mitigation |
|--------|-----------|
| Public internet scans | Zero open inbound ports on host |
| DDoS | Nodes unroutable from public internet |
| Agent rogue execution | Network scope bound to pod — cannot reach host OS or LAN |
| Unauthorized access | Cryptographic identity via Tailscale — Tailnet auth required |
| State persistence | Ephemeral containers — teardown wipes everything |

#### Future Hardening (roadmap, not current scope)
- L7 Egress Proxy (Squid WAF) — dstdomain allowlist
- `--read-only` filesystem + tmpfs shims
- Landlock kernel sandbox for workspace file access

## Key Findings
- **darius**: the host machine (192.168.86.69) — runs the Podman pod
- **pi-patch**: existing k3s cluster name (nodes: midas, ajax, tut, nero, darius) — NOT involved in ICEBox2
- **trixie-icebox**: the existing agent sandbox container image (debian:trixie-slim base)
- **Pure ephemeral**: no persistence — teardown wipes everything, including Tailnet registration
- **No cloud**: all runs locally on darius — Tailscale is the only external dependency

## Important Notes
- Tailscale ephemeral auth key must be pre-provisioned and stored securely (not in the container image)
- TS_USERSPACE=true avoids needing NET_ADMIN capability — keeps pod unprivileged
- Agent sandbox binds only to 127.0.0.1:8080 — no direct host network exposure
- Developer accesses via MagicDNS hostname, not IP — works from any device on the Tailnet
- icebox-config.yaml already exists in repo — likely the config for egress allowlists (Section 7)

## Phase 10 Complete Review — Landlock icebox-run (2026-06-06)

**APPROVED.** Thorough architectural review completed. Clean per-command Landlock sandbox with correct design. No blocking issues; known limitations documented below.

### Strengths

- **Inline ABI v4 definitions** — eliminates `linux-libc-dev` build-time dependency. Correct approach.
- **`_Static_assert` layout guards** — struct sizes pinned at compile time against kernel ABI (12-byte packed `ll_path_beneath`, 16-byte `ll_ruleset_attr`, 16-byte `ll_net_port`). Excellent defensive programming.
- **`PR_SET_NO_NEW_PRIVS` before `landlock_restrict_self`** — required by kernel; done correctly.
- **Config parsed before Landlock activated** — `/icebox/config.yaml` port list read before sandbox is applied. Child inherits restrictions; `/icebox` is inaccessible to the wrapped command. Correct ordering.
- **Graceful ABI fallback** — if kernel ABI < 4, warns and runs unrestricted. Fail-open is correct here (defense-in-depth, not hard dependency). darius runs 6.17 so full ABI v4 active.
- **Opt-in per-command** — not PID 1/entrypoint. sshd and code-server legitimately need broader access; correct to exclude them.
- **Syscall numbers 444/445/446 stable** — comment is accurate for both x86_64 and arm64.
- **`add_fs` silently skips absent paths** — `/lib64` absent on arm64 is harmless; `/lib` covers the dynamic linker.
- **64-port cap** — `int ports[64]` is sufficient for typical egress allowlists.
- **`icebox-run.c` in `_build_if_needed` trigger** — image rebuilds when source changes.
- **config.yaml mounted `:ro,Z`** — correct flags; config is immutable from container perspective.

### Known Limitations (documented, non-blocking)

1. **`/etc` not in FS allowlist (intentional)** — programs needing DNS (`/etc/resolv.conf`, `/etc/nsswitch.conf`), TLS (`/etc/ssl/certs`), or user lookups (`/etc/passwd`) will fail under `icebox-run`. The dynamic linker falls back gracefully (reads from `/lib`, `/usr/lib` which ARE allowed). BATS test 38 (`icebox-run restricts /etc/passwd read`) explicitly validates this. README must document: `icebox-run` is suitable for local file processing, not for commands making network calls unless the DNS-less path works.

2. **`/home/dev` not in FS allowlist (intentional)** — agents running `icebox-run <cmd>` cannot write to `~/.config/` etc. Agents should use `/workspace` or `/tmp` for all writes.

3. **UDP not restricted** — Landlock ABI v4 only covers TCP connect; UDP is unrestricted. Agents can still make UDP DNS lookups or other UDP traffic under `icebox-run`. Known Landlock v4 limitation. README should note this.

4. **Minimum kernel 6.10** — required for `LANDLOCK_ACCESS_NET_CONNECT_TCP` (ABI v4). darius is on 6.17 ✅. Older kernels fall back to unrestricted (warn only).

5. **`/dev` FS_RO is effectively a no-op** — Landlock v4 FS rights don't restrict character device access (char devices bypass FS rules). `/dev/null`, `/dev/urandom` remain accessible. Not a security gap (intended), just documentation clarity.

### Phase 11 Tasks Confirmed in Scope
- T11.2: README update needed — old architecture diagram, SSH agent forwarding, `make pull` still present
- T11.3: USER_GUIDE needed — document `icebox-run` usage, known limitations above, min kernel version
- T11.5 (add): Recommend README note on UDP limitation and DNS behavior under `icebox-run`

## Phase 9 Review — userns=auto + gVisor (2026-06-06)

**APPROVED.** Isolation depth increased per ADR-001 hardening roadmap.

- `--userns=auto` at pod level (correct scope); `--userns=keep-id` on sandbox run removed — pod-level wins
- `--runtime=$(ICEBOX_RUNTIME)` at pod level — propagates to all containers; TS_USERSPACE=true compatible with gVisor
- `receive.git` write access under userns=auto deferred to live test on darius (host UID mismatch is a known risk, explicitly noted in T9.1)
- gVisor apt source fixed to `$(dpkg --print-architecture)` for arm64 compatibility on darius

## Phase 8 Review — Git PR Flow (2026-06-06)

**APPROVED.** ADR-001 two-level git model correctly implemented.

- Host `.git` `:ro,Z` (agent workspace origin, read-only)
- `receive.git` `:Z` (agent push target, writable, host-side intermediary)
- `make down` removes receive.git — prevents `git clone --bare` collision on re-auth (Trin's catch)
- `make pr-list` / `make merge` are developer-side only — agent never touches host git state
- `safe.directory` not needed for remotes accessed by path; `--userns=keep-id` keeps UID parity

---
*Last updated: 2026-06-06*
