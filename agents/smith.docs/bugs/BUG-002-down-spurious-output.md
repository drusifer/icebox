# BUG-002: make down prints cleanup messages when no session is active

**Filed by:** Smith (HCI)  
**Severity:** Medium (no data loss; causes user confusion)  
**HCI Heuristic:** H1 — Visibility of system status

## Reproduction

```bash
cd ~/my-project   # no active icebox session
make -f ~/icebox/Icebox.mk down

# ACTUAL output:
# ==> No active session.
# ==> Stopping pod icebox-my-project-...
# ==> Deleting session keypair...
# ==> Done.

# EXPECTED output:
# ==> No active session.
```

## Root Cause

`Icebox.mk` `down` target:
```makefile
down: _check_podman
    @if [ -z "$(SESSION_ID)" ]; then \
        echo "==> No active session."; exit 0; \
    fi
    @echo "==> Stopping pod $(POD_NAME)..."   ← runs anyway
    @echo "==> Deleting session keypair..."   ← runs anyway
    @echo "==> Done."                          ← runs anyway
```

In Make, each `@cmd` is an independent shell invocation. `exit 0` inside the `@if` block exits only that sub-shell. Make continues running subsequent recipe lines regardless.

## Fix

Wrap the entire down body in a single `if/else/fi` shell block:

```makefile
down: _check_podman
    @if [ -z "$(SESSION_ID)" ]; then \
        echo "==> No active session."; \
    else \
        echo "==> Stopping pod $(POD_NAME)..."; \
        podman pod rm -f $(POD_NAME) > /dev/null 2>&1 || true; \
        echo "==> Deleting session keypair..."; \
        rm -f $(SESSION_DIR)/id_session $(SESSION_DIR)/id_session.pub $(SESSION_DIR)/dev.pub; \
        rm -rf $(SESSION_DIR)/receive.git; \
        rm -f $(SESSION_FILE); \
        echo "==> Done."; \
    fi
```

## UX Impact

User sees progress messages for operations that did not happen. After `podman pod rm` (which silently fails on a nonexistent pod), the output is the same whether a pod was stopped or not. Users lose confidence in what the tool actually did.
