# Cypher Context

## Recent Decisions

### 2026-06-04: ICEBox2 Sprint Stories Written

Wrote 7 user stories for ICEBox2 sprint. Key product decisions reflected:
- Tailscale sidecar replaces SSH as ingress mechanism
- code-server on 8080 replaces sshd
- waypipe for display forwarding (keeps exploits inside icebox)
- TS_AUTHKEY via env var or ~/.config/icebox/secrets (never in repo)
- Pod lifecycle (podman pod) replaces single-container model
- Session IDs for MagicDNS hostnames

## Key Findings
- **Existing system is Milestone 1 complete**: SSH, three modes, git write-back, BATS tests all working
- **ICEBox2 delta is focused**: 7 stories, all about replacing SSH ingress with Tailscale + code-server
- **PLAN.md is the historical Q&A record**: Q1-Q7 answers are authoritative product decisions
- **No registry publishing**: image stays local to developer's machine

## Important Notes
- Story 3 removes openssh-server from Dockerfile — breaking change to existing SSH workflow
- Story 7 BATS tests must not require live Tailscale — keep CI clean

---
*Last updated: 2026-06-04*
