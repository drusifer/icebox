**Project:** ICEbox (In-memory Containerized Environment)
**Status:** ICEBox2 Sprint Complete (2026-06-07)
**Stakeholders:**
*   **Product:** Drew
*   **Engineering:** ICEBox2 team (Neo, Trin, Morpheus)

---

### 1. Problem Statement

Modern software development requires working across numerous projects, each with its own complex web of dependencies, build tools, and scripts. This creates significant challenges:

*   **Host System Pollution:** Installing language versions, libraries, and tools directly on a host machine leads to conflicts and system "cruft," making the development environment fragile and difficult to manage.
*   **Security Risks:** Cloning and building untrusted repositories or running installation scripts (`curl ... | bash`) exposes the host system and local network to potential security vulnerabilities, including data exfiltration and ransomware.
*   **Lack of Reproducibility:** An inconsistent environment makes it difficult to reproduce builds and diagnose issues, leading to "it works on my machine" problems.

Developers need a way to instantly create a sandboxed, project-specific workspace that is completely isolated from their host OS, without a complex setup process.

### 2. Proposed Solution

**ICEbox** is a secure, ephemeral, and containerized development environment managed by a single `Makefile`. By running `make`, a developer can instantly provision a fully isolated workspace for any project.

The core principle is **volatility as a feature**. The environment is intentionally non-persistent; it is rebuilt from a clean state on every startup. The only data that survives a session is the code committed to the project's `.git` repository, which is securely mounted from the host. All build artifacts, dependencies, and other transient files are discarded when the container stops.

To provide flexibility, ICEbox will offer distinct **Operational Modes** that allow the user to choose the right balance between security and resource consumption for the task at hand.

### 3. Goals & Success Metrics

*   **Goal:** Provide a zero-setup, secure-by-default development environment.
    *   **Metric:** A developer can clone a new project, add the `Makefile`, and have a running, VS Code-accessible environment with a single `make` command.
*   **Goal:** Ensure complete isolation from the host filesystem.
    *   **Metric:** No build artifacts or transient files are ever written to the host's source directory. All writes are confined to in-memory filesystems or a designated temporary host directory, depending on the operational mode.
*   **Goal:** Maintain a non-privileged security posture.
    *   **Metric:** The container and all its processes run as a non-root user on the host, with `no-new-privileges` set and all non-essential Linux capabilities dropped.

### 4. Non-Goals

*   **Production Deployments:** ICEbox is designed exclusively for development and testing. It is not intended or hardened for running production applications.
*   **Preserving Build Artifacts:** The core design principle is that all build artifacts are ephemeral and are intentionally discarded when the container stops.

### 5. User Stories

*   **As a developer,** I want to clone any project, drop the `icebox` `Makefile` into it, and run `make`, so that a fully configured, secure, and isolated development environment is created automatically.
*   **As a developer,** I want the setup to run without requiring `sudo` on my host machine, so that I can maintain a standard, unprivileged workflow.
*   **As a developer,** I want my project's source code to be automatically checked out into an in-memory workspace when the container starts, so I can immediately begin working.
*   **As a developer,** I want to connect to my running environment using VS Code with a single command, so that I can use my preferred editor without complex configuration.
*   **As a system administrator,** I want to be confident that the development environment is completely isolated, cannot write build artifacts to the host disk, and cannot escalate its privileges, ensuring host system integrity.
*   **As a system administrator,** I want visibility into security-relevant events happening within the container, such as outbound network connections.

### 6. Requirements & Specifications

#### 6.1. Lifecycle Management
All container operations shall be managed via a `Makefile` interface, abstracting away the underlying Podman commands.
*   `make up`: Creates and starts the container. Can accept an optional `MODE` parameter (e.g., `make up MODE=zero_leakage`).
*   `make down`: Stops the running container.
*   `make clean`: Stops and removes all container resources, including any disk-backed caches.
*   `make ssh-config`: Generates the SSH configuration needed for VS Code Remote-SSH.

#### 6.2. Operational Modes
The user can select a mode at creation time to tailor the environment's filesystem strategy.
*   **Standard Mode (Default):** A balanced configuration using in-memory `tmpfs` for the workspace and home directory, while mapping large, disposable caches (e.g., `node_modules`, `venv`) to a temporary directory on the host (`/var/tmp`) to conserve RAM.
*   **Zero Leakage Mode (High-Security):** An extreme isolation setting that guarantees zero disk writes from the container. All writable paths, including caches, are backed by in-memory `tmpfs`.
*   **Resource Saver Mode (Low-Memory):** Optimized for systems with limited RAM. This mode uses disk-backed shims for all possible volatile locations, **including the primary workspace**. This minimizes memory consumption at the cost of I/O performance.

#### 6.3. Filesystem Architecture
*   **Immutable Root:** The container's root filesystem (`/`) must be mounted as read-only.
*   **Volatile Storage:** All non-persistent storage (workspaces, caches, temp files) must be managed via `tmpfs` mounts or disk-backed bind-mounts to a dedicated temporary host directory (e.g., `/var/tmp/icebox/<project>`), as determined by the operational mode.
*   **Persistent Git History:** The host project's `.git` directory is the single source of truth and must be bind-mounted into the container.
*   **Automated State Restoration:** Upon startup, the container must automatically perform a `git checkout` from the mounted `.git` directory into the volatile workspace. The system shall attempt to check out the branch that is currently active in the host repository.

#### 6.4. Security & Permissions
*   **Rootless Execution:** The container must be executed by Podman within a user namespace, mapping the container's internal root user to a non-privileged user on the host.
*   **Privilege Restriction:** The container must run with the `no-new-privileges` security option.
*   **Capability Minimization:** The environment must drop all non-essential Linux capabilities (`--cap-drop=ALL`).

#### 6.5. Network Posture
*   **Default Access:** The container shall have unrestricted outbound access to the public internet. The primary mitigation for risks associated with this policy (e.g., from `curl ... | bash`) is the container's ephemeral and isolated nature, which severely limits the "blast radius" of any malicious code.
*   **Ingress Policy:** Inbound connections from any external network are strictly forbidden. The only entrypoint shall be via SSH from the host machine.
*   **Internal Access:** Access to internal (host or LAN) network resources is forbidden by default. It can be enabled by passing a list of networks or hosts via an environment variable (e.g., `ICEBOX_ALLOW_NETWORKS="192.168.1.0/24,10.0.0.5"`).
*   **Logging:** The container image shall be equipped with standard network diagnostic tools (e.g., `conntrack-tools`, `ss`, `tcpdump`) to allow an administrator to monitor network activity on demand.

#### 6.6. Developer Experience
*   **Seamless SSH Access:** The setup process must automate the injection of the user's public SSH key into the container's `authorized_keys` file. It will default to using `~/.ssh/id_ed25519.pub` but should allow overriding this path via an environment variable.
*   **Secret Management:** The system should provide a recommended pattern for managing secrets (e.g., API keys) via runtime environment variables passed during container creation.

### 7. Open Questions (Milestone 1)

1.  What is the performance impact of `Zero Leakage Mode` on large projects with many dependencies that cannot be cached on disk?
2.  What is the optimal logging strategy for network connections that provides visibility without overwhelming the user or creating performance overhead?

---

## ICEBox2 — Tailscale Ephemeral Sidecar (Sprint Complete 2026-06-07)

### Motivation

Milestone 1 required the developer to be on the same LAN as the host and used direct SSH. It also did not address the threat model of **potentially-compromised AI agents** (tool-enabled LLMs with code execution). ICEBox2 hardens the security posture and adds cloud-accessible ephemeral sessions without any cloud infrastructure.

### User Stories (ICEBox2)

- **S1 — Session lifecycle:** As a developer, I want to run `make auth` from any git project root and have an ephemeral sandbox pod created with a unique session ID, so that I can isolate AI agent work from my host machine.
- **S2 — Tailscale access:** As a developer, I want the sandbox to register an ephemeral Tailscale node, so that I can access it from any device on my Tailnet without opening inbound ports on the host.
- **S3 — waypipe terminal:** As a developer, I want `make auth` to open a `foot` terminal forwarded via `waypipe ssh` over Tailscale, so that I have a Wayland-native terminal to the sandbox without a separate SSH step.
- **S4 — code-server access:** As a developer, I want code-server available at `http://icebox-<session>.<tailnet>:8080`, so that I can use VS Code-compatible editing from any browser on my Tailnet.
- **S5 — Agent PR workflow:** As a developer, I want the agent to push branches to an `upstream` remote (receive.git), and use `make pr-list` / `make merge` to review and accept agent work, so that I control what lands on my host working tree.
- **S6 — Ephemeral cert delegation:** As a developer, I want a fresh session keypair generated per session and injected into the sandbox, separate from my own SSH keys, so that compromised session credentials cannot impersonate me.
- **S7 — Config-driven setup:** As a developer, I want `icebox-config.yaml` in my project root to declare credentials, repos, extra mounts, and egress ports, so that the sandbox is configured declaratively without modifying the Icebox.mk.

### Security Requirements (ICEBox2)

| Requirement | Implementation |
|---|---|
| No inbound host ports | Tailscale inverted ingress (developer connects out to Tailnet) |
| Host/LAN unreachable from container | `--network=pasta` on Podman pod |
| Ephemeral session identity | Tailscale ephemeral auth key; auto-purged on pod removal |
| Agent cannot overwrite host working tree | `.git` mounted `:ro`; writes via `receive.git` intermediary only |
| Minimum privilege | `--cap-drop=ALL`, `--read-only`, `no-new-privileges`, `--pids-limit=256` |
| User namespace isolation | `--userns=auto` at pod level |
| Process-level FS + net restrictions | `icebox-run` Landlock ABI v4 wrapper (optional, per-command) |
| Optional syscall interception | gVisor runtime (`ICEBOX_RUNTIME=runsc`) |

### Completed (ICEBox2 Sprint)

All 11 phases implemented and verified. See [STATUS.md](STATUS.md) for the full phase completion list and [task.md](task.md) for the sprint task board.