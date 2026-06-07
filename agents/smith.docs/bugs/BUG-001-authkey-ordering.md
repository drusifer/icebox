# BUG-001: _check_authkey runs after _build_if_needed

**Filed by:** Smith (HCI)  
**Severity:** High (affects every first-time user)  
**HCI Heuristic:** H9 — Help users recognize, diagnose, and recover from errors

## Reproduction

```bash
# On a machine where the image has never been built:
cd ~/my-project
make -f ~/icebox/Icebox.mk auth   # TS_AUTHKEY not set
# ACTUAL: 5+ minute image build runs, THEN "TS_AUTHKEY is not set" error
# EXPECTED: Immediate error before any build occurs
```

## Root Cause

`Icebox.mk` line 46:
```makefile
auth: _check_podman _check_git _check_config _build_if_needed _check_authkey
```

`_check_authkey` is position 5, after `_build_if_needed` (position 4). Make runs prerequisites left-to-right.

## Fix

Move `_check_authkey` before `_build_if_needed`:
```makefile
auth: _check_podman _check_git _check_config _check_authkey _build_if_needed
```

## UX Impact

A developer setting up ICEbox for the first time, who has not yet stored their TS_AUTHKEY, will wait 5–10 minutes for a full image build (downloading 500MB+ of packages) before being told about the missing key. They must then fix the key and wait through the build again — or it was already built, so auth proceeds fine the second time. Either way, the first-time error experience is terrible.
