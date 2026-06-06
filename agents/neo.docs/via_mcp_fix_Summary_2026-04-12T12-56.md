# via MCP Fix Summary - 2026-04-12T12:56

## Problem
Codex reported:

```text
MCP client for `via` failed to start: handshaking with MCP server failed: connection closed: initialize response
```

## Findings
- `.via/index.db` was missing, and `via mcp serve /home/drusifer/Projects/bob_protocol` exited before MCP initialize.
- After indexing, `via` still failed in the sandbox because it wrote logs to `/home/drusifer/.via/mcp.log`, which is read-only in this environment.
- `via mcp serve` starts the web UI by default; port binding can fail and kill the MCP process.

## Changes
- Added `ensure_via_index()` in `agents/tools/setup_agent_links.py`.
- Hardened project `.mcp.json` by adding `env.HOME=<project-root>` and `--no-web`.
- Updated Codex MCP registration to use `--env HOME=<project-root>` and `mcp serve --no-web <project-root>`.
- Added `make test` and `make via_index`.
- Added focused unit tests in `tests/test_setup_agent_links.py`.
- Updated active Codex MCP config and built `.via/index.db`.

## Verification
- `make via_index V=-vv` passed and created the index.
- `make test V=-vv` passed with 4 tests.
- `codex mcp get via` shows `args: mcp serve --no-web /home/drusifer/Projects/bob_protocol` and `env: HOME=*****`.
