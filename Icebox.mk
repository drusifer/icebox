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

.PHONY: auth connect status down clean build help test-setup test \
        _build_if_needed _session_start _check_podman _check_git _check_config _check_authkey

## auth: Build image (if needed), provision pod, print MagicDNS URL.
auth: _check_podman _check_git _check_config _build_if_needed _check_authkey
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
	@ssh-keygen -t ed25519 -f $(SESSION_DIR)/id_session -N "" -q
	@chmod 644 $(SESSION_DIR)/id_session
	@echo "==> Creating pod $(NEW_POD)..."
	@mkdir -p $(SESSION_DIR)/ts-state
	@podman pod create --name $(NEW_POD) --network=pasta
	@echo "==> Starting Tailscale sidecar..."
	@podman run --pod $(NEW_POD) \
		--name $(NEW_POD)-ts \
		--detach \
		--rm \
		-e TS_USERSPACE=true \
		-e TS_HOSTNAME=icebox-$(NEW_SESSION_ID) \
		-e TS_AUTHKEY=$(TS_AUTHKEY) \
		-e TS_STATE_DIR=/tmp/tailscale \
		--volume $(SESSION_DIR)/ts-state:/tmp/tailscale:Z \
		docker.io/tailscale/tailscale:latest
	@echo "==> Waiting for Tailscale to connect..."
	@for i in $$(seq 1 30); do \
		if podman exec $(NEW_POD)-ts tailscale status --json 2>/dev/null | grep -q '"Online":true'; then \
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
		--userns=keep-id \
		--security-opt "no-new-privileges" \
		--cap-drop=ALL \
		--cap-add=CHOWN \
		--cap-add=DAC_OVERRIDE \
		--cap-add=FOWNER \
		--cap-add=SETUID \
		--cap-add=SETGID \
		--pids-limit=256 \
		--read-only \
		--mount type=tmpfs,destination=/run \
		--mount type=tmpfs,destination=/tmp \
		--mount type=tmpfs,destination=/home/$(DEV_USER) \
		--mount type=tmpfs,destination=/workspace \
		--volume "$(CURDIR)/.git:/icebox/.git:ro,Z" \
		--volume "$(SESSION_DIR)/id_session:/icebox/id_session:ro,Z" \
		--dns $(ICEBOX_DNS) \
		-e "DEV_USER=$(DEV_USER)" \
		-e "ICEBOX_GIT_BRANCH=$(shell git -C "$(CURDIR)" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)" \
		$(REPO_MOUNTS) \
		$(EXTRA_MOUNTS) \
		$(IMAGE_NAME)
	@echo "==> Waiting for code-server health check..."
	@for i in $$(seq 1 20); do \
		if podman exec $(NEW_POD)-sandbox curl -sf http://127.0.0.1:8080 > /dev/null 2>&1; then \
			echo "==> code-server ready."; break; \
		fi; \
		if [ "$$i" -eq 20 ]; then \
			echo "Warning: code-server health check timed out (may still be starting)."; \
		fi; \
		sleep 1; \
	done
	@TAILNET=$$(podman exec $(NEW_POD)-ts tailscale status --json 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix','<tailnet>'))" 2>/dev/null || echo "<tailnet>"); \
	echo ""; \
	echo "==> ICEbox ready."; \
	echo ""; \
	echo "    http://icebox-$(NEW_SESSION_ID).$${TAILNET}:8080"; \
	echo ""; \
	echo "    make -f $(THIS_MAKEFILE) connect   # open waypipe GUI tunnel"; \
	echo "    make -f $(THIS_MAKEFILE) down       # stop and clean up"; \
	echo ""

## connect: Open waypipe tunnel from host to the running ICEbox pod.
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
	@if ! command -v socat &> /dev/null; then \
		echo "Error: socat not found. Install with 'sudo apt install socat'."; \
		exit 1; \
	fi
	@TAILNET=$$(podman exec $(POD_NAME)-ts tailscale status --json 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix','<tailnet>'))" 2>/dev/null || echo ""); \
	if [ -z "$$TAILNET" ]; then \
		echo "Error: Cannot determine Tailnet suffix. Is the pod running?"; \
		exit 1; \
	fi; \
	HOST="icebox-$(SESSION_ID).$${TAILNET}"; \
	CSOCK="/tmp/waypipe-icebox-$(SESSION_ID).sock"; \
	echo "==> Bridging waypipe from $$HOST:7681 to $$CSOCK ..."; \
	socat UNIX-LISTEN:$$CSOCK,fork TCP:$$HOST:7681 & \
	SOCAT_PID=$$!; \
	trap "kill $$SOCAT_PID 2>/dev/null; rm -f $$CSOCK" EXIT; \
	sleep 1; \
	waypipe --socket $$CSOCK client; \
	kill $$SOCAT_PID 2>/dev/null; \
	rm -f $$CSOCK

## status: List running ICEbox pods and their MagicDNS URLs.
status: _check_podman
	@echo "==> Running ICEbox pods:"; \
	podman pod ls --format "{{.Name}}\t{{.Status}}" | grep "^icebox-" | while IFS=$$'\t' read -r name status; do \
		sid=$$(echo "$$name" | awk -F- '{print $$NF}'); \
		echo "  $$name  [$$status]  http://icebox-$${sid}.<tailnet>:8080"; \
	done

## down: Stop and remove the pod, delete session keypair.
down: _check_podman
	@if [ -z "$(SESSION_ID)" ]; then \
		echo "==> No active session."; exit 0; \
	fi
	@echo "==> Stopping pod $(POD_NAME)..."
	@podman pod rm -f $(POD_NAME) > /dev/null 2>&1 || true
	@echo "==> Deleting session keypair..."
	@rm -f $(SESSION_DIR)/id_session $(SESSION_DIR)/id_session.pub
	@rm -f $(SESSION_FILE)
	@echo "==> Done."

## clean: down + delete all host artifacts for this project.
clean: down
	@echo "==> Deleting host artifacts..."
	@rm -rf $(SESSION_DIR)
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
	    [ "$(ICEBOX_DIR)entrypoint.sh" -nt "$(BUILD_STAMP)" ]; then \
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
	@echo "Host prerequisites: podman, waypipe"
	@echo "Auth key:           TS_AUTHKEY env var or ~/.config/icebox/secrets"

## test-setup: Initialize BATS testing submodules.
test-setup:
	@mkdir -p test_helper
	@if ! grep -q 'path = test_helper/bats-support' .gitmodules 2>/dev/null; then \
		git submodule add https://github.com/bats-core/bats-support test_helper/bats-support; \
	fi
	@if ! grep -q 'path = test_helper/bats-assert' .gitmodules 2>/dev/null; then \
		git submodule add https://github.com/bats-core/bats-assert test_helper/bats-assert; \
	fi
	@git submodule update --init --recursive

## test: Run the BATS test suite.
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
