## Recent Decisions

- Created `docs/` directory as the canonical home for planning/architecture docs that aren't top-level user-facing files.
- `task.md` intentionally stays at root — Mouse's SKILL.md, memory.md, and CHAT.md all explicitly reference it there.
- Removed stale links to `STARTUP.md` and `SHORTHAND_GUIDE.md` from `DOCUMENTATION_INDEX.md` — neither file exists in this repo.

## Key Findings

- **Root orphans moved**: `PLAN.md`, `implementation_plan.md`, `ICEBox2.md` → `docs/`
  - Multiple agent docs (cypher.docs/STORIES.md, mouse.docs/context.md) reference these by filename without path; agents will need to locate them via grep/via if referencing by path.
- **`docs/ICEBox2.md`** is the canonical architecture spec for the current version (v2, Tailscale Ephemeral Sidecar). `agents/morpheus.docs/arch-decisions.md` is the companion ADR list.
- **DOCUMENTATION_INDEX.md** had two stale links (STARTUP.md, SHORTHAND_GUIDE.md) — removed.
- **README.md** now has a Documentation table linking all key docs.
- **STATUS.md** updated to point at `docs/implementation_plan.md`.

## Important Notes
- `REQUIREMENTS.md`, `STATUS.md`, `USER_GUIDE.md` remain at root — they are user-facing and expected there.
- `task.md` at root is Mouse's sprint board — do not move it.
- `agents/neo.docs/via_mcp_fix_Summary_2026-04-12T12-56.md` is a fix note from a different project (bob_protocol) and appears to be informational; left in place.

---
*Last updated: 2026-06-06*
