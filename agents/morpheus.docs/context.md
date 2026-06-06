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

---
*Last updated: 2026-06-04*
