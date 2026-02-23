# ICEbox — Milestone 2+ Implementation Plan

This document captures the gap analysis between the current ICEbox implementation
and the features described in the article, along with a proposed implementation plan.

Add comments inline with `> your comment` or answer the open questions directly.

---

## Gap Analysis Summary

### What Already Works ✅

- Rootless Podman with capability dropping (`--cap-drop=ALL`)
- Read-only root filesystem + tmpfs for `/workspace` and `/home/vscode`
- Ephemeral container (all changes discarded on exit)
- Git workspace auto-checkout at startup (active branch detected from host `.git/HEAD`)
- SSH access with auto-detected public key injection
- Three operational modes: `standard`, `zero_leakage`, `resource_saver`
- VS Code Remote-SSH integration
- BATS test suite with bats-support / bats-assert

### What Is Missing ❌

| # | Feature | Article Quote | Status |
|---|---------|---------------|--------|
| G1 | `Icebox.mk` as a distributable file | *"copying the Icebox Make file (Icebox.mk) into the root directory of a new or existing git repo"* | Not implemented — currently `Makefile`, co-located with `entrypoint.sh` |
| G2 | Git write-back to host | *"git commit applies the local changes in the container to the git repo checkout on the host system"* | Blocked — `.git` is mounted read-only; commits vanish with the container |
| G3 | SSH agent / certificate forwarding | *"leverage the user's authorization using ssh-agent and certificate forwarding... no visibility of the user's private ssh keys"* | Not implemented — no `SSH_AUTH_SOCK` forwarding |
| G4 | Network filtering / LAN blocking | *"only allow-listed internet is visible, and there are no inbound routes"* | Not implemented — container has full LAN + internet access |
| G5 | Display forwarding (waypipe / RDP) | *"VSCode session is launched inside the container and displayed on the host device via waypipe/rdp"* | Not implemented — SSH terminal only |
| G6 | `icebox` Make target | *"`make -f IceBox.mk icebox`"* | Not implemented — current entry point is `make up` |

---

## Open Questions

Please answer or add comments below each question. These decisions affect the
implementation approach.

---

### Q1 — Image Distribution Strategy

For `Icebox.mk` to be truly distributable (drop it into any repo and run), it
needs to reference a container image that doesn't require a local build step.

**Options:**

**A) Publish to a registry (GitHub Container Registry, Docker Hub, etc.)**
- User copies `Icebox.mk`, runs `make -f Icebox.mk icebox`
- Image is pulled automatically on first run
- Requires a published image at a known tag (e.g., `ghcr.io/USERNAME/icebox:latest`)
- Cleanest UX — true single-file drop-in

**B) Keep local build, require `entrypoint.sh` alongside `Icebox.mk`**
- User copies both `Icebox.mk` and `entrypoint.sh` into their repo
- First run builds the image locally
- No registry needed, slightly more friction to distribute

**C) Embed `entrypoint.sh` into the Dockerfile, keep local build**
- `entrypoint.sh` is baked into the image at build time
- `Icebox.mk` only needs the `Dockerfile` alongside it (or a pre-built image)
- Middle ground — still requires a build step, but one fewer file to copy

> **Your answer / comment:**

The idea is that you have a checkout of icebox somehere besides the project folder that you are editing.  The makefile should handle almost everything with the caveat that icebox requires some depenecies to be installed first.  Let's make that clear and we can experiment with including images and other artifacts in the icebox repo and/or have the makefile handle any intermeadite steps. Option A seems like a good approach for this.
---

### Q2 — Git Write-back Architecture

The article says `git commit` in the container applies changes to the host. Two
approaches are viable:

**A) Make the `.git` bind mount writable**
- Remove `:ro` from `--mount type=bind,source=$(PWD)/.git,destination=/icebox/.git`
- In the container: `git push origin HEAD:branchname` sends commits to the host's `.git`
- After exiting, the user runs `git pull` (or `make pull`) on the host to update their working tree
- After exiting, the user runs `git pull` (or `make pull`) on the host to update their working tree
- After exiting, the user runs `git pull` (or `make pull`) on the host to update their working tree
- Downside: After container exit the host working tree is stale until you pull

**B) Mount the entire project directory as a writable bind mount**
- `/workspace` maps directly to the host project directory (like a normal devcontainer)
- `git commit` in the container commits directly to the host's `.git` AND updates the working tree
- Agent edits are immediately visible on the host (before any commit)
- Simpler mental model but breaks strict "only commits escape the container" guarantee
- Uncommitted agent writes persist on host as untracked changes

> **Preferred approach?**
>
> **Your answer / comment:**

---
The goal here is to add protection against rogue agents doing bad stuff with the repo. does A provide greater protectgion than B?  If both the same then lets go with B to make it simple but only if option A is ineffective as a security control 


### Q3 — Network Filtering Implementation Approach

Blocking LAN access from a rootless Podman container is the most technically
complex gap. The challenge: rootless Podman uses slirp4netns (or pasta), which
NATs traffic through the host. Blocking RFC1918 ranges requires intervening at
the host firewall or container network namespace level.

**Options:**

**A) Host-level nftables/iptables rules (requires `sudo`)**
- After `podman run`, apply nftables rules to the container's network namespace
- Blocks all RFC1918 destinations: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
- Most reliable approach — works regardless of Podman network backend
- Requires `sudo nft` or `sudo iptables` — is this acceptable for a home setup?

**B) Podman `pasta` network backend**
- `pasta` (newer Podman alternative to slirp4netns) has more filtering options
- Potentially rootless LAN blocking via `--network=pasta:...` flags
- May not be installed by default on Raspberry Pi / Debian Trixie
- Lower user friction if available

**C) In-container DNS + egress filtering proxy**
- Run a companion filtering proxy/DNS container
- Route all ICEbox traffic through it (no sudo needed on host)
- Proxy blocks RFC1918 destinations
- Complex to set up; adds another moving part

**D) `--network=none` with opt-in networks**
- Block ALL network by default
- User explicitly opts into internet access via `ICEBOX_ALLOW_NETWORKS`
- Very safe, but breaks the "can use AI tools that call APIs" use case
- Could be a separate mode: `make icebox MODE=airgapped`

> **Which approach fits your home setup? Is `sudo` acceptable for the firewall step?**
>
> **Is pasta available / installed on darius (your Raspberry Pi)?** (`command -v pasta`)
>
> **Your answer / comment:**

---
I want the network filtering to be outside the container so a roughte agent can't modify or circument the control. pasta is installed but let's use an alternative approach.  I have a pihole set up that I can use to filter via allowlist. So we should make the icebox container use the filtered pihole DNS as a separate groug.  Containers -> filtered pyhole , non-containers -> unfiltered pi hole.

### Q4 — Display Forwarding Scope

The article mentions waypipe/RDP so a full GUI (e.g., VSCode running inside the
container) is displayed on the host. However:

- Claude Code runs in the terminal — no display needed
- VS Code Remote-SSH (already working) runs the IDE on the host, only the language
  server runs in the container — no display needed for this either
- Waypipe/RDP would only be needed if you want to run the full VSCode binary
  *inside* the container and display it on the host

> **Is display forwarding needed for your use case, or is VS Code Remote-SSH + Claude Code in the terminal sufficient?**
>
> **Your answer / comment:**
Yes this is key.  If i ssh then my terminal which is running my locally is a target by forwarding the display we keep any exploit via shell or vscode bugs inside the icebox and away from the host system.

---

### Q5 — `ICEBOX_ALLOW_NETWORKS` Behavior

The REQUIREMENTS.md already specifies an opt-in mechanism for allowing specific
LAN resources:

> `ICEBOX_ALLOW_NETWORKS="192.168.1.0/24,10.0.0.5"`

Questions on semantics:

- Should this allow the listed CIDRs in addition to public internet (additive)?
- Or should internet be blocked by default and this list is the only allowed traffic?
- When the article says "only allow-listed internet is visible" — does "internet"
  mean just public IP ranges, or does it include specific LAN hosts you trust?

> **Your answer / comment:**
I realy want this feature to be user controled so that the developer can open up internal apis if needed.  For now we can block all and backlog this requirement.
---

### Q6 — Container Image Tag Strategy

If publishing to a registry (Q1 Option A), what tagging strategy?

- `latest` only (simple, always current)
- Semantic versioning (`v1.0`, `v1.1`, etc.)
- Date-based tags (`2026-02-22`)
- Git SHA tags (for exact reproducibility)

> **Your answer / comment:**
N/A - we the icebox container should not be published to any registries, It's private the the developer and the local host.
---

### Q7 — Default Mode After Rename

The article workflow is just `make -f Icebox.mk` (no explicit target) which means
the default `all` target runs. Currently `all: help`.

Should the default target:

**A)** Print help (current behavior — safe, no side effects)
**B)** Run the `icebox` / `up` target directly (convenient but starts a container on `make`)
**C)** Run a pre-flight check and prompt the user

> **Your answer / comment:**

option B
---

---

## Decisions & Analysis

### D1 — Invocation Model (from Q1 + Q6)

Icebox lives in its own checkout (e.g., `~/icebox`). It is **not** copied into
each project repo. The invocation from any project is:

```bash
cd /path/to/my-project
make -f ~/icebox/Icebox.mk icebox
```

`Icebox.mk` uses `$(dir $(lastword $(MAKEFILE_LIST)))` to resolve its own
directory at runtime, so it can find `Dockerfile` and `entrypoint.sh` regardless
of where it is invoked from. The image is built locally and tagged
`localhost/icebox:latest`. No registry is used.

**User workflow (one-time setup):**
```bash
git clone <icebox-repo> ~/icebox
cd ~/icebox && make build        # builds localhost/icebox:latest
```

**Per-project usage:**
```bash
cd my-project
make -f ~/icebox/Icebox.mk       # starts icebox (default target = icebox)
```

A shell alias (`alias icebox='make -f ~/icebox/Icebox.mk'`) makes this even
cleaner. The Makefile should document required host dependencies (podman, git,
ssh-keygen, etc.) and optionally check for them at startup.

---

### D2 — Git Write-back: Recommendation is Option A (from Q2)

**Option A (tmpfs workspace + writable `.git` remote) provides stronger
protection than Option B.** Here is why:

| Scenario | Option A (tmpfs + writable .git) | Option B (writable bind mount) |
|---|---|---|
| Agent writes a malicious hidden file (`.bashrc`, `.gitconfig`) | Stays in tmpfs, gone on exit | Lands directly on host filesystem |
| Agent downloads a binary to workspace | Stays in tmpfs, gone on exit | Lands directly on host filesystem |
| Agent writes outside git-tracked paths | Stays in tmpfs, gone on exit | Persists on host as untracked file |
| Agent modifies a tracked source file | Must `git push` to persist | Immediately visible on host |
| Ransomware encrypts workspace files | Tmpfs is gone on exit | Host files are encrypted |

With Option A, the **only** content that can escape the container is content
the user explicitly commits and pushes. With Option B, any agent write —
committed or not — lands on the host immediately.

**Recommendation: Keep Option A.** The `.git` bind mount will be changed from
read-only to writable. The container workflow becomes:

