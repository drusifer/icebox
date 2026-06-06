# Next Steps

## Immediate Next Action
Hand off to Mouse for sprint decomposition, or Neo for implementation start.

## Waiting On
User direction on which to do first:
- A) `@mouse *sm plan` — sprint plan from ADR-001
- B) `@neo *swe impl` — start Terraform + Makefile scaffolding

## Planned Work
- [ ] Review Neo's Terraform scaffold for infra/terraform/ (Fleet registration, GKE Autopilot, IAP, VPC)
- [ ] Review icebox-session.yaml template (gVisor RuntimeClass, NetworkPolicy, emptyDir)
- [ ] Review Makefile targets (up/connect/down/status)
- [ ] Approve or veto ACM policy structure (cluster/ vs namespaces/)
- [ ] pi-patch Fleet registration playbook review (Ansible role or gcloud commands)

## Resume Instructions (cold start)
1. Read context.md — ADR-001 has the full locked architecture
2. Architecture is complete — next work is implementation
3. Check CHAT.md for any Neo/Mouse handoff messages
4. Pick up review of whatever Neo has scaffolded

---
*Last updated: 2026-06-02*
