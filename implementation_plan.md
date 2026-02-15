# ICEbox Implementation Plan

This document outlines the plan to complete the implementation of ICEbox according to the requirements in `REQUIREMENTS.md` and to satisfy the tests in `test_icebox.bats`.

### 1. Current State

Basic dev container is working on Raspberry Pi (arm64). Image builds from Dockerfile (`trixie` + `openssh-server`), container starts with `make up`, SSH pubkey auth works, filesystem mounts are correct (tmpfs workspace/home, disk-backed cache, read-only root).

### 2. Active Work

- **Entrypoint Permissions:** The `Makefile` has to run `chmod +x entrypoint.sh` before `podman run`. This is a workaround for file permissions not being preserved. The entrypoint script should be made executable in the repository.
- **Test Suite Updates:** Tests need updating to match current implementation (new image, no `.git` mount, `build` step, corrected output messages).

### 3. Backlog

- **Git Workspace Restoration:** Mount the host's `.git` directory read-only and checkout the active branch into the volatile `/workspace` on container startup. Run checkout as `DEV_USER` for correct file ownership.
- **Network Security (`ICEBOX_ALLOW_NETWORKS`):** Restrict LAN access by default, allow opt-in via environment variable. Requires further investigation into podman network filtering capabilities.

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
