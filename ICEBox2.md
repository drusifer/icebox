# Architecture Specification: ICEbox

**Version:** 2.0
**Pattern:** Tailscale Ephemeral Sidecar (Inverted Ingress)
**Environment:** Local Headless Compute (darius — 192.168.86.69)
**Last updated:** 2026-06-05

---

## 1. Executive Summary

ICEbox is an automate-first, zero-trust development enclave for agentic coding. It runs untrusted AI agent workloads in a heavily sandboxed ephemeral container on local hardware, with zero inbound public ports and cryptographically-enforced identity-aware access via Tailscale.

The threat model is **untrusted content inside the container**: an AI agent that goes rogue, executes malicious code, or attempts to exfiltrate credentials or pivot to the host. Defense is applied in concentric layers — each layer assumes the one inside it has already been compromised.

---

## 2. Component Topology

A single Podman pod encapsulates the session. All containers share one network namespace; lateral movement within the pod uses localhost only.

### Host (darius)

- Compute substrate only. No inbound firewall ports opened.
- Podman rootless — no daemon, no root.
- `--network=pasta` on the pod: user-mode networking; host and LAN are not reachable from inside the pod.

### Container A — Tailscale Sidecar (`tailscale/tailscale:latest`)

- Authenticates via ephemeral `TS_AUTHKEY`; registers `icebox-<session-id>` on the Tailnet.
- `TS_USERSPACE=true` — avoids `NET_ADMIN`; runs entirely in userspace.
- Provides the pod's inbound ingress path: developer machines reach the pod exclusively via the Tailscale WireGuard tunnel.
- On teardown, the ephemeral key causes the control plane to purge the node record instantly.

### Container B — Agent Sandbox (`trixie-icebox:latest`)

- Runs `sshd` (Tailscale-only, locked-down config) + `code-server` (optional web IDE).
- `sshd_config`: `AllowTcpForwarding no`, `PermitTunnel no`, `AllowAgentForwarding no`, `X11Forwarding no`.
- Primary developer access: `waypipe ssh dev@icebox-<session-id>.<tailnet> foot` — native Wayland terminal rendered on the developer's host desktop.
- Agent processes are launched through the **Landlock wrapper** (`icebox-run`) which applies per-process filesystem and network restrictions.

---

## 3. Developer Access Flow

```
Developer desktop
  └── waypipe client (host)
        │  WireGuard tunnel (Tailscale MagicDNS)
        ▼
  Tailscale sidecar (Container A)
        │  shared network namespace (localhost)
        ▼
  sshd (Container B, port 22)
        │  SSH session
        ▼
  foot terminal (Wayland, forwarded back through waypipe to developer desktop)
        │
  Developer runs agents here
```

`make auth` is the single entry point: builds image, creates receive.git, starts the pod, waits for Tailscale + sshd readiness, then exec's `waypipe ssh ... foot` — the developer lands in a terminal on their desktop.

---

## 4. Git Workflow (Agent → Host → Upstream)

The `.git` directory is bind-mounted **read-only** into the container for workspace initialisation. To get code changes back to the host without re-opening the git hook injection vector, a **bare receive repository** acts as intermediary:

```
Host .git (ro) ──clone──► /workspace (tmpfs, container)
                                  │
                           agent git push <branch>
                                  │
                                  ▼
             /var/tmp/icebox/<project>/receive.git  (bare, rw bind-mount)
                                  │
                 host: git fetch receive.git        ← host .git hooks only; never container hooks
                                  │
                        host reviews + merges
                                  │
                        host git push upstream
```

**Why a bare intermediary is safe:** `git fetch` on the host executes hooks from the *fetching* repository's `.git/hooks` directory (the host's own), never from the remote. Hooks planted by the agent in `receive.git/hooks` are never executed on the host.

### Host-side targets

| Target | Action |
|--------|--------|
| `make auth` | Creates `receive.git`, starts pod, opens terminal |
| `make pr-list` | Lists branches pushed to `receive.git` |
| `make merge BRANCH=<b>` | Fetches branch from `receive.git` and merges into host working tree |
| `make down` | Stops pod, deletes session keypair |
| `make clean` | `down` + deletes all host artifacts including `receive.git` |

### Agent-side workflow (inside pod)

```bash
git checkout -b agent/my-fix
# ... edit, test ...
git commit -m "fix: description"
git push upstream agent/my-fix   # upstream remote → /var/tmp/.../receive.git
```

---

## 5. Security Layer Model

Defense is applied in concentric layers. Each layer is independent; compromise of an inner layer does not defeat outer layers.

```
┌─────────────────────────────────────────────────────────┐
│  Host kernel                                            │
│  ┌───────────────────────────────────────────────────┐  │
│  │  gVisor (runsc)                                   │  │
│  │  Intercepts all container syscalls in userspace.  │  │
│  │  A kernel exploit inside cannot reach the real    │  │
│  │  kernel.                                          │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │  Pod                                        │  │  │
│  │  │  --network=pasta  (host/LAN unreachable)    │  │  │
│  │  │  --userns=auto    (container root ≠ host    │  │  │
│  │  │                    user; breakout = nobody) │  │  │
│  │  │  ┌───────────────────────────────────────┐  │  │  │
│  │  │  │  Container B (sandbox)                │  │  │  │
│  │  │  │  AppArmor profile (enabled)           │  │  │  │
│  │  │  │  --cap-drop=ALL + minimal adds        │  │  │  │
│  │  │  │  --read-only root fs                  │  │  │  │
│  │  │  │  --pids-limit=256                     │  │  │  │
│  │  │  │  all mounts ro or tmpfs               │  │  │  │
│  │  │  │  ┌─────────────────────────────────┐  │  │  │  │
│  │  │  │  │  Agent process (icebox-run)      │  │  │  │  │
│  │  │  │  │  Landlock (kernel 6.12, ABI v4): │  │  │  │  │
│  │  │  │  │  · fs: /workspace only           │  │  │  │  │
│  │  │  │  │  · net: allowlist ports only     │  │  │  │  │
│  │  │  │  └─────────────────────────────────┘  │  │  │  │
│  │  │  └───────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Layer responsibilities

| Layer | What it stops |
|-------|--------------|
| gVisor | Kernel exploits; syscall-based escapes |
| `--userns=auto` | Post-breakout process owns nothing on host |
| `--network=pasta` | Access to host, LAN, other cluster nodes |
| AppArmor | Dangerous file/syscall access patterns |
| `--cap-drop=ALL` | Capability-based privilege escalation |
| `--read-only` + ro mounts | Agent writing to container filesystem or host mounts |
| `--pids-limit` | Fork bombs |
| Landlock (fs) | Agent reading outside `/workspace` (credentials, host .git, `/etc`) |
| Landlock (net, ABI v4) | Agent connecting to arbitrary IPs/ports (egress deny-by-default) |

### Threat mitigations

| Threat | Mitigation |
|--------|-----------|
| Public internet scans | Zero open inbound ports on host |
| DDoS | Nodes unroutable from public internet |
| Agent pivots to host | `--network=pasta` + `--userns=auto` |
| Agent reads credentials | Landlock fs restricts to `/workspace`; session key at staging path, copied to tmpfs |
| Git hook injection | `.git` mounted read-only; `core.hooksPath /dev/null` in container |
| Agent exfiltrates data | Landlock net allowlist (egress deny-by-default) |
| Container breakout | gVisor intercepts syscalls; userns remaps identity |
| Fork bomb | `--pids-limit=256` |
| State persistence | Ephemeral tmpfs; pod teardown wipes all volatile state |
| SSH forwarding/tunneling | `AllowTcpForwarding no`, `AllowAgentForwarding no` in sshd |

---

## 6. Landlock Wrapper (`icebox-run`)

The Landlock wrapper is a small C binary compiled into the image at `/usr/local/bin/icebox-run`.

**Startup sequence:**
1. Read `/icebox/config.yaml` (ro mount of `icebox-config.yaml`)
2. `landlock_create_ruleset` with `LANDLOCK_ACCESS_FS_*` + `LANDLOCK_ACCESS_NET_*` (ABI v4)
3. `landlock_add_rule`: allow read/write/execute on `/workspace`; allow `/tmp` read/write
4. `landlock_add_rule`: allow TCP `connect()` on ports listed in `icebox-config.yaml` `egress.ports`; deny all others
5. `landlock_restrict_self` — restrictions locked; inherited by all children, cannot be removed
6. `execvp(argv[1], argv+1)` — exec the agent command

**Usage:**
```bash
icebox-run claude          # agent restricted to /workspace + egress allowlist
icebox-run python train.py # untrusted script, same restrictions
```

Restrictions are **inherited and irremovable** — code the agent writes and executes cannot bypass them.

---

## 7. Configuration (`icebox-config.yaml`)

```yaml
# SSH key names under ~/.ssh/ for agent git auth (ephemeral session keypair)
credentials:
  - github

# Additional repos to clone into /workspace
repos:
  - url: https://github.com/myorg/shared-lib.git
    path: /var/tmp/icebox/repos/shared-lib  # optional cache path

# Additional host paths to bind-mount (read-only by default)
mounts:
  - host: /home/user/datasets
    container: /workspace/datasets
    # rw: true  # opt-in for writable mounts

# Landlock network egress allowlist (ports the agent may connect() to)
# Applied by icebox-run wrapper. Deny-by-default for all other ports.
egress:
  ports:
    - 443   # HTTPS
    - 80    # HTTP
    - 22    # git+ssh to remotes
```

---

## 8. Lifecycle

```
make auth
  1. Build trixie-icebox image (if stale)
  2. mkdir /var/tmp/icebox/<project>/receive.git → git clone --bare <host .git>
  3. Generate session keypair → /var/tmp/icebox/<project>/id_session (chmod 644)
  4. podman pod create --network=pasta [--runtime=runsc if gVisor available]
  5. Start Tailscale sidecar; wait for Online=true
  6. Start sandbox container (ro mounts, tmpfs workspace, staging key)
  7. Wait for sshd ready (poll port 22 via Tailscale)
  8. Print: session ID, MagicDNS hostname, code-server URL
  9. exec: waypipe ssh dev@icebox-<session-id>.<tailnet> foot
     └── Developer is now in a native Wayland terminal on their desktop

make down
  1. podman pod rm -f <pod>           ← Tailscale control plane purges node
  2. rm session keypair
  3. rm .session file

make clean
  1. make down
  2. rm -rf /var/tmp/icebox/<project>  ← includes receive.git
```

---

## 9. Backlog (future hardening)

- **L7 Egress Proxy (Squid WAF):** Domain-level allowlist as complement to Landlock port allowlist. Prevents connecting to known-bad IPs on allowed ports.
- **`ICEBOX_ALLOW_NETWORKS`:** Opt-in flag to grant access to specific internal network ranges (e.g., for internal package registries).
- **Pi-hole DNS group:** Route container DNS through a filtered Pi-hole group to block known malicious domains at the resolver level.
- **Vault/PKI integration:** Derived per-session certificates for mTLS to internal services, replacing static credentials.
- **Landlock symlink/ioctl hardening (ABI v3):** Already available on kernel 6.12; add to wrapper.
