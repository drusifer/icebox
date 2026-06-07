# Smith Context — ICEBox2 UX Review (2026-06-07)

## Recent Decisions

- Full UX review of ICEBox2 CLI surface conducted against Nielsen's 10 heuristics.
- Two blocking bugs filed. Three non-blocking concerns documented.

## Key Findings

### BUG-1 (Blocking): `_check_authkey` runs AFTER image build — H9 violation
- **WHAT**: `auth:` target order is `_check_podman _check_git _check_config _build_if_needed _check_authkey`. A first-time user without `TS_AUTHKEY` set will sit through a multi-minute image build before seeing the "TS_AUTHKEY is not set" error.
- **WHY**: Make runs prerequisites left-to-right. `_build_if_needed` is #4; `_check_authkey` is #5.
- **HCI**: H9 — Help users recognize, diagnose, and recover from errors. Errors should surface immediately, not after expensive side effects.
- **FIX**: Move `_check_authkey` before `_build_if_needed`: `auth: _check_podman _check_git _check_config _check_authkey _build_if_needed`

### BUG-2 (Blocking): `make down` with no session prints spurious cleanup messages — H1 violation
- **WHAT**: `exit 0` inside `@if [ -z "$(SESSION_ID)" ]; then ... exit 0; fi` exits only that recipe's sub-shell. Make then runs subsequent `@echo` lines unconditionally, printing "Stopping pod...", "Deleting session keypair...", "Done." even with no active session.
- **WHY**: Each `@cmd` in a Makefile recipe is a separate shell invocation. `exit 0` scopes to its shell only.
- **HCI**: H1 — Visibility of system status. User sees progress messages for operations that did not occur.
- **FIX**: Wrap entire `down` body in a single `if/else/fi` shell block so `exit 0` on the no-session path suppresses all subsequent output.

### CONCERN-1 (Non-blocking): `make status` silent when no pods running — H1
- **WHAT**: Output is just `==> Running ICEbox pods:` followed by nothing.
- **FIX**: Add "No running ICEbox pods." when `podman pod ls` returns no icebox matches.

### CONCERN-2 (Non-blocking): `make auth` help description misleading — H10
- **WHAT**: Help says "Build image (if needed), provision pod, print MagicDNS URL." `make auth` actually blocks indefinitely, opening an interactive waypipe terminal. A user reading the description expects a quick, non-blocking command.
- **FIX**: "Build image, start pod, open waypipe terminal (blocks until exit)."

### CONCERN-3 (Non-blocking): `test-setup` and `test` in user-facing help — H8
- **WHAT**: `make help` lists developer targets (`test-setup`, `test`) alongside user targets. Adds cognitive noise for end users.
- **FIX**: Prefix these with `##` instead of `## ` so they are excluded from the help pattern, or add a `## dev:` section separator.

## Positives

- Error messages are generally excellent: "No .git directory. Run icebox from a git repo root." and "icebox-config.yaml not found. Copy one from..." both follow H9 perfectly — plain language + actionable fix.
- `make pr-list`, `make merge`, `make down` (no-session), `make connect` (no-session) all give clear, immediately useful errors.
- `make help` output is readable, uses color consistently, and shows prereqs and auth key hints at the bottom.
- `icebox-config.yaml` schema is well-commented — users can self-serve without docs.

## Important Notes

- BUG-1 is the highest priority — affects every first-time user on a fresh machine.
- BUG-2 is low blast-radius (no data loss) but creates user confusion about what actually ran.
- CONCERN-2 is important for user expectation-setting — `make auth` is the primary entry point.

## Re-test Results (2026-06-07 — after Trin fixes)

All five issues verified against running software:

| Issue | Test | Verdict |
|---|---|---|
| BUG-001: authkey before build | `make auth TS_AUTHKEY=` → immediate error, no build triggered | ✅ PASS |
| BUG-002: down spurious output | `make down` (no session) → "No active session." only | ✅ PASS |
| CONCERN-1: status empty state | `make status` (no pods) → `(none)` shown | ✅ PASS |
| CONCERN-2: auth description | `make help` → "open waypipe terminal (blocks until exit)" | ✅ PASS |
| CONCERN-3: test targets in help | `make help` → test-setup and test absent | ✅ PASS |

**All bugs closed. UX approved.**

---
*Last updated: 2026-06-07*
