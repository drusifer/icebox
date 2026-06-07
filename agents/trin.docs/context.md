## Recent Decisions

- Image-dependent tests (23-27) correctly skip when image not built — this is expected behavior, not a gap
- `_build_if_needed` must watch all files COPYed into the image, not just Dockerfile/entrypoint.sh

## Key Findings

- **`sshd_config` missing from rebuild trigger** — fixed in UAT; future Dockerfiles that COPY new files must update `_build_if_needed`
- **`dev.pub` cleanup gap** — `make down` test didn't cover dev.pub; fixed by extending existing test
- **27/27 passing** — 22 dry-run, 5 skip (image not built); image tests verified by grep/structural checks

## Important Notes
- Image tests (30-34) require `make build` on darius to fully execute
- Phase 7 waypipe ssh uses `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` — acceptable for ephemeral sessions on a private Tailnet
- Phase 8: receive.git must be removed in `make down` (not just `clean`) — otherwise re-auth fails because `git clone --bare` refuses to overwrite existing directory
- Phase 9: gVisor apt source must use `$(dpkg --print-architecture)` not hardcoded `amd64` — darius is arm64
- Phase 10: Landlock struct sizes must match kernel ABI exactly — added _Static_assert to icebox-run.c and a -fsyntax-only BATS test to catch regressions before image build

---
*Last updated: 2026-06-06*
