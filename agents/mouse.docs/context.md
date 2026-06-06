# Mouse Context

## Recent Decisions

### 2026-06-04: Direction pivot — Anthos cloud plan discarded
User redirected project. Previous ADR-001 (Anthos/GKE/Terraform) is scrapped entirely.
New direction: ICEBox2 spec (`ICEBox2.md`) — local Podman + Tailscale ephemeral sidecar on darius.
No cloud, no Kubernetes, no Terraform. Simple bash orchestration.

## Key Findings
- **task.md does not exist yet** — no sprint has been started
- **ICEBox2.md** is the canonical spec — all planning must derive from it
- **Existing repo artifacts** (Dockerfile, entrypoint.sh, icebox-config.yaml, Makefile, Icebox.mk) may be reusable
- **trixie-icebox** container image already exists — check what it provides before rebuilding

## Important Notes
- Sprint 1 scope should be: bash orchestration script + Tailscale sidecar integration + wiring trixie-icebox to pod
- Do NOT plan Terraform, ACM, or any cloud infra work — that plan is dead
- icebox-config.yaml likely maps to Section 7 of ICEBox2.md (egress allowlists)

---
*Last updated: 2026-06-04*
