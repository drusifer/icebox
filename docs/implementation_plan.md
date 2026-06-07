# ICEbox Implementation Plan

This document outlines the plan to complete the implementation of ICEbox according to the requirements in `REQUIREMENTS.md` and to satisfy the tests in `test_icebox.bats`.

### 1. Milestone 1: Core Features (Complete)

- **Entrypoint Permissions:** `entrypoint.sh` is executable in git. No `chmod +x` workaround needed.
- **Git Workspace Restoration:** Host `.git` mounted read-only at `/icebox/.git`. Entrypoint runs `git init` + `git fetch` + `git checkout` into `/workspace` as `DEV_USER`. Branch name passed via `ICEBOX_GIT_BRANCH` env var.
- **Test Suite:** Updated to match current implementation — cache mount checks FSTYPE not SOURCE, clean output message aligned, curl added to image for internet test.
- **Dockerfile:** Added `curl` to apt install for dev use and test assertions.

### 2. Backlog

- **Network Security / URL Filtering:** Restrict LAN access by default, allow opt-in via environment variable. Requires Squid proxy + SSL bump — deferred to its own milestone due to complexity.

---

## Milestone 2: K3s Cluster for ICEbox Containers

### Context

ICEbox currently runs individual Podman containers on a single host. This milestone orchestrates ICEbox containers across a small cluster of 3-5 Raspberry Pis using Kubernetes (K3s).

The previous attempt used K3s in **rootless mode**, which trapped Flannel's VXLAN inside a user namespace. This required a fragile socat bridge sidecar to forward UDP traffic between host and namespace — it never worked reliably. The ~10 shell scripts accumulated 16+ workarounds and hardcoded IPs.

This milestone replaces all of that with:
- **Standard (root) K3s** — Flannel gets direct host network access, networking just works
- **WireGuard backend** — encrypted inter-node tunnels, no VXLAN complexity
- **Ansible** — declarative, idempotent provisioning of all nodes
- **Helm** — declarative K8s-level configuration (namespaces, pod security, ICEbox workload templates)

### Architecture

```
[Developer Laptop]
    |
    | ansible-playbook -i inventory/hosts.yml playbooks/site.yml
    v
[midas (server)]  <--WireGuard-->  [ajax (agent)]  <--WireGuard-->  [node3 (agent)]
   192.168.86.32                    192.168.86.33                    192.168.86.x
   K3s server                       K3s agent                        K3s agent
```

### Files Created

```
cluster/
├── ansible.cfg
├── inventory/hosts.yml
├── roles/
│   ├── common/tasks/main.yml
│   ├── k3s-server/{tasks,templates,handlers}/
│   ├── k3s-agent/{tasks,templates,handlers}/
│   └── k3s-security/tasks/main.yml
├── playbooks/
│   ├── site.yml
│   ├── nuke.yml
│   └── validate.yml
└── helm/icebox/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/{namespace,pod-security,deployment}.yaml
```

### Files Deleted

Replaced by Ansible/Helm:
- `01-nuke.sh`, `02-prep.sh`, `03-config.sh`, `04-launch.sh`, `05-validate.sh`
- `k3-setup.sh`, `k3-join.sh`, `k3-bridge.sh`, `k3-install.sh`, `k3-validate.sh`

### Verification

1. **Provision**: `cd cluster && ansible-playbook playbooks/site.yml`
2. **Check nodes**: `kubectl get nodes -o wide` — all nodes Ready
3. **Check WireGuard**: `sudo wg show` on any node — shows active peer tunnels
4. **Validate**: `ansible-playbook playbooks/validate.yml` — cross-node ping test
5. **Deploy ICEbox**: `helm install my-env ./helm/icebox/`
6. **Teardown**: `ansible-playbook playbooks/nuke.yml`
