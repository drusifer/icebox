# ==============================================================================
# Icebox.mk — ICEbox: Ephemeral Dev Sandbox via Tailscale Sidecar
#
# Usage (from any git repo root):
#   make -f /path/to/icebox/Icebox.mk auth     # build + start pod + print MagicDNS URL
#   make -f /path/to/icebox/Icebox.mk connect  # open waypipe tunnel to running pod
#   make -f /path/to/icebox/Icebox.mk status   # list running icebox pods
#   make -f /path/to/icebox/Icebox.mk down     # stop + remove pod, delete session key
#   make -f /path/to/icebox/Icebox.mk clean    # down + delete all host artifacts
# ==============================================================================

SHELL := /bin/bash

THIS_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
ICEBOX_DIR    := $(dir $(THIS_MAKEFILE))

PROJECT_NAME := $(shell basename "$(CURDIR)")
IMAGE_NAME   ?= localhost/trixie-icebox:latest
BUILD_STAMP  := $(ICEBOX_DIR).build-stamp

DEV_USER     ?= dev
ICEBOX_DNS   ?= 192.168.86.10

# Session state
SESSION_DIR  := /var/tmp/icebox/$(PROJECT_NAME)
SESSION_FILE := $(SESSION_DIR)/.session
SESSION_ID   := $(shell cat $(SESSION_FILE) 2>/dev/null)
POD_NAME     := icebox-$(PROJECT_NAME)-$(SESSION_ID)

# Repo cache dir for additional repos from config
REPO_CACHE_DIR := /var/tmp/icebox/repos

# TS_AUTHKEY: env var → ~/.config/icebox/secrets → error
TS_AUTHKEY ?= $(shell grep -s '^TS_AUTHKEY=' $(HOME)/.config/icebox/secrets | cut -d= -f2-)

# SSH_KEY_PATH: developer's public key staged into container authorized_keys
SSH_KEY_PATH ?= $(firstword $(wildcard $(HOME)/.ssh/id_*.pub))

# ICEBOX_RUNTIME: container runtime; set to runsc for gVisor isolation (default: crun)
ICEBOX_RUNTIME ?= crun

.PHONY: auth connect status down clean build help test-setup test pr-list merge \
        _build_if_needed _session_start _check_podman _check_git _check_config _check_authkey

## auth: Build image (if needed), start pod, open waypipe terminal (blocks until exit).
auth: _check_podman _check_git _check_config _check_authkey _build_if_needed
	@if [ -n "$(SESSION_ID)" ] && podman pod exists $(POD_NAME) 2>/dev/null; then \
		echo "==> ICEbox '$(POD_NAME)' is already running."; \
		echo "==> Connect: make -f $(THIS_MAKEFILE) connect"; \
	else \
		$(MAKE) -f $(THIS_MAKEFILE) --no-print-directory _session_start; \
	fi

_session_start:
	@mkdir -p $(SESSION_DIR)
	$(eval NEW_SESSION_ID := $(shell openssl rand -hex 3))
	@echo $(NEW_SESSION_ID) > $(SESSION_FILE)
	$(eval NEW_POD := icebox-$(PROJECT_NAME)-$(NEW_SESSION_ID))
	@echo "==> Generating session keypair..."
	@rm -f $(SESSION_DIR)/id_session $(SESSION_DIR)/id_session.pub
	@ssh-keygen -t ed25519 -f $(SESSION_DIR)/id_session -N "" -q
	@chmod 600 $(SESSION_DIR)/id_session
	@if [ -z "$(SSH_KEY_PATH)" ]; then \
		echo "Error: No SSH public key found in ~/.ssh/. Set SSH_KEY_PATH=~/.ssh/your_key.pub"; \
		exit 1; \
	fi
	@cp "$(SSH_KEY_PATH)" $(SESSION_DIR)/dev.pub
	@chmod 644 $(SESSION_DIR)/dev.pub
	@echo "==> Creating receive.git bare clone..."
	@rm -rf "$(SESSION_DIR)/receive.git"
	@git clone --bare "$(CURDIR)/.git" "$(SESSION_DIR)/receive.git" -q
	@echo "==> Creating pod $(NEW_POD)..."
	@mkdir -p $(SESSION_DIR)/ts-state
	@podman pod create --name $(NEW_POD) --network=pasta --userns=auto:size=65536 --runtime=$(ICEBOX_RUNTIME)
	@echo "==> Starting Tailscale sidecar..."
	@podman run --pod $(NEW_POD) \
		--name $(NEW_POD)-ts \
		--detach \
		--rm \
		-e TS_USERSPACE=true \
		-e TS_HOSTNAME=icebox-$(NEW_SESSION_ID) \
		-e TS_AUTHKEY=$(TS_AUTHKEY) \
		-e TS_STATE_DIR=/tmp/tailscale \
		--volume $(SESSION_DIR)/ts-state:/tmp/tailscale:Z,U \
		docker.io/tailscale/tailscale:latest
	@echo "==> Waiting for Tailscale to connect..."
	@for i in $$(seq 1 30); do \
		if podman exec $(NEW_POD)-ts tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; then \
			echo "==> Tailscale connected."; break; \
		fi; \
		if [ "$$i" -eq 30 ]; then \
			echo "Error: Tailscale did not connect within 30s. Check TS_AUTHKEY."; \
			podman pod rm -f $(NEW_POD) > /dev/null 2>&1 || true; \
			rm -f $(SESSION_FILE); \
			exit 1; \
		fi; \
		sleep 1; \
	done
	@$(MAKE) -f $(THIS_MAKEFILE) --no-print-directory _start_sandbox NEW_POD=$(NEW_POD) NEW_SESSION_ID=$(NEW_SESSION_ID)

_start_sandbox:
	@echo "==> Starting sandbox container..."
	@# Clone any additional repos from config to host-side cache
	@if [ -f "$(CURDIR)/icebox-config.yaml" ]; then \
		python3 -c " \
import sys, yaml; \
cfg = yaml.safe_load(open('$(CURDIR)/icebox-config.yaml')) or {}; \
repos = cfg.get('repos', []) or []; \
[print(r['url'] + '|' + r.get('path', '$(REPO_CACHE_DIR)/' + r['url'].rstrip('/').split('/')[-1].replace('.git',''))) for r in repos if isinstance(r, dict) and 'url' in r] \
" 2>/dev/null | while IFS='|' read -r url path; do \
			mkdir -p "$$path"; \
			if [ ! -d "$$path/.git" ]; then \
				echo "==> Cloning $$url to $$path..."; \
				git clone --mirror "$$url" "$$path"; \
			fi; \
		done; \
	fi
	@# Build extra repo volume mounts
	$(eval REPO_MOUNTS := $(shell \
		if [ -f "$(CURDIR)/icebox-config.yaml" ]; then \
			python3 -c " \
import sys, yaml; \
cfg = yaml.safe_load(open('$(CURDIR)/icebox-config.yaml')) or {}; \
repos = cfg.get('repos', []) or []; \
mounts = []; \
[mounts.append('--volume ' + r.get('path', '$(REPO_CACHE_DIR)/' + r.get('url','').rstrip('/').split('/')[-1].replace('.git','')) + ':/icebox/repos/' + r.get('url','').rstrip('/').split('/')[-1].replace('.git','') + ':ro,Z') for r in repos if isinstance(r, dict) and r.get('url')]; \
print(' '.join(mounts)) \
" 2>/dev/null; fi))
	@# Validate and fail fast on missing host paths for explicit mounts
	@if [ -f "$(CURDIR)/icebox-config.yaml" ]; then \
		python3 -c " \
import yaml, sys; \
cfg = yaml.safe_load(open('$(CURDIR)/icebox-config.yaml')) or {}; \
mounts = cfg.get('mounts', []) or []; \
missing = [m.get('host','') for m in mounts if isinstance(m, dict) and not __import__('os').path.exists(m.get('host',''))]; \
[sys.exit('Error: mount host path does not exist: ' + p) for p in missing if p] \
" 2>&1 || exit 1; \
	fi
	$(eval EXTRA_MOUNTS := $(shell \
		if [ -f "$(CURDIR)/icebox-config.yaml" ]; then \
			python3 -c " \
import yaml; \
cfg = yaml.safe_load(open('$(CURDIR)/icebox-config.yaml')) or {}; \
mounts = cfg.get('mounts', []) or []; \
flags = []; \
[flags.append('--volume ' + m.get('host','') + ':' + m.get('container','') + (':Z' if m.get('rw', False) else ':ro,Z')) for m in mounts if isinstance(m, dict) and m.get('host') and m.get('container')]; \
print(' '.join(flags)) \
" 2>/dev/null; fi))
	@podman run --pod $(NEW_POD) \
		--name $(NEW_POD)-sandbox \
		--detach \
		--rm \
		--security-opt "no-new-privileges" \
		--cap-drop=ALL \
		--cap-add=CHOWN \
		--cap-add=DAC_OVERRIDE \
		--cap-add=FOWNER \
		--cap-add=SETUID \
		--cap-add=SETGID \
		--cap-add=SYS_CHROOT \
		--pids-limit=256 \
		--read-only \
		--mount type=tmpfs,destination=/run \
		--mount type=tmpfs,destination=/tmp \
		--mount type=tmpfs,destination=/home/$(DEV_USER) \
		--mount type=tmpfs,destination=/workspace \
		--volume "$(CURDIR)/.git:/icebox/.git:ro,Z" \
		--volume "$(SESSION_DIR)/receive.git:/icebox/receive.git:Z" \
		--volume "$(SESSION_DIR)/dev.pub:/icebox/dev.pub:ro,Z" \
		--volume "$(CURDIR)/icebox-config.yaml:/icebox/config.yaml:ro,Z" \
		--dns $(ICEBOX_DNS) \
		-e "DEV_USER=$(DEV_USER)" \
		-e "ICEBOX_GIT_BRANCH=$(shell git -C "$(CURDIR)" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)" \
		$(REPO_MOUNTS) \
		$(EXTRA_MOUNTS) \
		$(IMAGE_NAME)
	@TAILNET=$$(podman exec $(NEW_POD)-ts tailscale status --json 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix','<tailnet>'))" 2>/dev/null || echo "<tailnet>"); \
	echo "==> Waiting for sshd..."; \
	for i in $$(seq 1 30); do \
		if podman exec $(NEW_POD)-sandbox pgrep -x sshd > /dev/null 2>&1; then \
			echo "==> sshd ready."; break; \
		fi; \
		if [ "$$i" -eq 30 ]; then \
			echo "Warning: sshd readiness check timed out."; break; \
		fi; \
		sleep 1; \
	done; \
	echo ""; \
	echo "==> ICEbox ready."; \
	echo "    code-server: http://icebox-$(NEW_SESSION_ID).$${TAILNET}:8080"; \
	echo "    make -f $(THIS_MAKEFILE) down"; \
	echo ""; \
	echo "==> Opening terminal (waypipe ssh)..."; \
	waypipe --remote-socket /run/user/1000/waypipe \
		ssh -p 2222 \
		-i $(patsubst %.pub,%,$(SSH_KEY_PATH)) \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o SetEnv='XDG_RUNTIME_DIR=/run/user/1000' \
		dev@icebox-$(NEW_SESSION_ID).$${TAILNET} foot

## connect: Re-attach a waypipe terminal to the running ICEbox pod.
##          Requires waypipe installed on the host.
connect: _check_podman
	@if [ -z "$(SESSION_ID)" ]; then \
		echo "Error: No active ICEbox session. Run 'make auth' first."; \
		exit 1; \
	fi
	@if ! command -v waypipe &> /dev/null; then \
		echo "Error: waypipe not found. Install with 'sudo apt install waypipe'."; \
		exit 1; \
	fi
	@TAILNET=$$(podman exec $(POD_NAME)-ts tailscale status --json 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix','<tailnet>'))" 2>/dev/null || echo ""); \
	if [ -z "$$TAILNET" ]; then \
		echo "Error: Cannot determine Tailnet suffix. Is the pod running?"; \
		exit 1; \
	fi; \
	waypipe --remote-socket /run/user/1000/waypipe \
		ssh -p 2222 \
		-i $(patsubst %.pub,%,$(SSH_KEY_PATH)) \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o SetEnv='XDG_RUNTIME_DIR=/run/user/1000' \
		dev@icebox-$(SESSION_ID).$${TAILNET} foot

## pr-list: List branches the agent has pushed to receive.git.
pr-list:
	@if [ ! -d "$(SESSION_DIR)/receive.git" ]; then \
		echo "Error: receive.git not found. Run 'make auth' first."; \
		exit 1; \
	fi
	@echo "==> Branches in receive.git:"; \
	git -C "$(SESSION_DIR)/receive.git" branch -a

## merge: Fetch and merge an agent branch from receive.git into the current host branch.
##        Usage: make merge BRANCH=<branch>
merge:
	@if [ -z "$(BRANCH)" ]; then \
		echo "Error: BRANCH is required. Usage: make -f $(THIS_MAKEFILE) merge BRANCH=<branch>"; \
		exit 1; \
	fi
	@if [ ! -d "$(SESSION_DIR)/receive.git" ]; then \
		echo "Error: receive.git not found. Run 'make auth' first."; \
		exit 1; \
	fi
	@echo "==> Fetching $(BRANCH) from receive.git..."
	git -C "$(CURDIR)" fetch "$(SESSION_DIR)/receive.git" "$(BRANCH):$(BRANCH)"
	@echo "==> Merging $(BRANCH)..."
	git -C "$(CURDIR)" merge --no-ff "$(BRANCH)"

## status: List running ICEbox pods and their MagicDNS URLs.
status: _check_podman
	@echo "==> Running ICEbox pods:"; \
	PODS=$$(podman pod ls --format "{{.Name}}\t{{.Status}}" 2>/dev/null | grep "^icebox-"); \
	if [ -z "$$PODS" ]; then \
		echo "  (none)"; \
	else \
		echo "$$PODS" | while IFS=$$'\t' read -r name status; do \
			sid=$$(echo "$$name" | awk -F- '{print $$NF}'); \
			echo "  $$name  [$$status]  http://icebox-$${sid}.<tailnet>:8080"; \
		done; \
	fi

## down: Stop and remove the pod, delete session keypair and receive.git.
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

## clean: down + delete all host artifacts for this project.
clean: down
	@echo "==> Deleting host artifacts..."
	@rm -rf $(SESSION_DIR)
	@rm -f $(BUILD_STAMP)
	@echo "==> Cleanup complete."

## build: Force-rebuild the ICEbox container image.
build: _check_podman
	@echo "==> Building ICEbox image from $(ICEBOX_DIR)..."
	podman build -t $(IMAGE_NAME) $(ICEBOX_DIR)
	@touch $(BUILD_STAMP)

_build_if_needed:
	@if ! podman image exists $(IMAGE_NAME) 2>/dev/null || \
	    [ ! -f "$(BUILD_STAMP)" ] || \
	    [ "$(ICEBOX_DIR)Dockerfile" -nt "$(BUILD_STAMP)" ] || \
	    [ "$(ICEBOX_DIR)entrypoint.sh" -nt "$(BUILD_STAMP)" ] || \
	    [ "$(ICEBOX_DIR)sshd_config" -nt "$(BUILD_STAMP)" ] || \
	    [ "$(ICEBOX_DIR)icebox-run.c" -nt "$(BUILD_STAMP)" ]; then \
		echo "==> Building ICEbox image..."; \
		podman build -t $(IMAGE_NAME) $(ICEBOX_DIR) && touch $(BUILD_STAMP); \
	else \
		echo "==> Image up to date, skipping build."; \
	fi

## help: Show available targets.
help:
	@echo "ICEbox targets:"
	@grep -E '^## [a-zA-Z_-]+:' $(THIS_MAKEFILE) | sed 's/^## //' | \
		awk 'BEGIN {FS = ": "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Host prerequisites: podman, waypipe, Wayland compositor"
	@echo "Auth key:           TS_AUTHKEY env var or ~/.config/icebox/secrets"

### test-setup: Initialize BATS testing submodules.
test-setup:
	@mkdir -p test_helper
	@if ! grep -q 'path = test_helper/bats-support' .gitmodules 2>/dev/null; then \
		git submodule add https://github.com/bats-core/bats-support test_helper/bats-support; \
	fi
	@if ! grep -q 'path = test_helper/bats-assert' .gitmodules 2>/dev/null; then \
		git submodule add https://github.com/bats-core/bats-assert test_helper/bats-assert; \
	fi
	@git submodule update --init --recursive

### test: Run the BATS test suite.
test:
	@if ! command -v bats &> /dev/null; then \
		echo "Error: bats not found. Install with 'sudo apt install bats'."; \
		exit 1; \
	fi
	bats test_icebox.bats

# --- Guards ---

_check_podman:
	@command -v podman &>/dev/null || { echo "Error: podman not found."; exit 1; }

_check_git:
	@[ -d "$(CURDIR)/.git" ] || { echo "Error: No .git directory. Run icebox from a git repo root."; exit 1; }

_check_config:
	@if [ ! -f "$(CURDIR)/icebox-config.yaml" ]; then \
		echo "Error: icebox-config.yaml not found in $(CURDIR)."; \
		echo "Copy one from the icebox repo: cp $(ICEBOX_DIR)icebox-config.yaml $(CURDIR)/"; \
		exit 1; \
	fi

_check_authkey:
	@if [ -z "$(TS_AUTHKEY)" ]; then \
		echo "Error: TS_AUTHKEY is not set."; \
		echo "Options:"; \
		echo "  1. export TS_AUTHKEY=tskey-auth-..."; \
		echo "  2. echo 'TS_AUTHKEY=tskey-auth-...' >> ~/.config/icebox/secrets"; \
		echo "  Get a key at: https://login.tailscale.com/admin/settings/keys"; \
		exit 1; \
	fi
