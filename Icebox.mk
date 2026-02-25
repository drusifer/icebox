# ==============================================================================
# Icebox.mk — ICEbox: Secure Ephemeral Development Environment
#
# Run from any git repository root:
#   make -f /path/to/icebox/Icebox.mk          # start (default target)
#   make -f /path/to/icebox/Icebox.mk down     # stop
#   make -f /path/to/icebox/Icebox.mk pull     # sync host working tree after commits
#
# Or via the installed wrapper (after make install):
#   icebox
# ==============================================================================

SHELL := /bin/bash

# Self-locate: resolve the directory containing this file regardless of where
# make is invoked from. Used to find the Dockerfile / build context.
THIS_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
ICEBOX_DIR    := $(dir $(THIS_MAKEFILE))

# --- Project identity (derived from the invoking directory, not the icebox repo) ---
PROJECT_NAME   := $(shell basename "$(CURDIR)")
CONTAINER_NAME := icebox-$(PROJECT_NAME)

# --- Image ---
IMAGE_NAME  ?= localhost/icebox:latest
BUILD_STAMP := $(ICEBOX_DIR).build-stamp

# --- SSH key auto-detection ---
FIRST_AVAILABLE_SSH_KEY := $(shell find $(HOME)/.ssh/id_*.pub -type f -print -quit 2>/dev/null)
SSH_KEY_PATH ?= $(FIRST_AVAILABLE_SSH_KEY)

# --- User-configurable overrides ---
# MODE: 'standard' (default), 'zero_leakage', or 'resource_saver'
MODE     ?= standard
DEV_USER ?= dev
# ICEBOX_ENV_VARS: pass extra env vars e.g. make icebox ICEBOX_ENV_VARS="-e FOO=bar"
ICEBOX_ENV_VARS ?=
# ICEBOX_DNS: DNS server for the container (Pi-hole filtered group)
ICEBOX_DNS ?= 192.168.86.10

# --- Host cache directory for disk-backed modes ---
HOST_TMP_DIR := /var/tmp/icebox/$(PROJECT_NAME)

# --- SSH agent forwarding ---
# Forwarded when SSH_AUTH_SOCK is set on the host. Allows git push to remotes
# without private keys being present inside the container.
# SSH_AUTH_SOCK may be a symlink (common with systemd/gpg-agent); resolve to
# the real socket path so the container bind-mount targets the actual file.
ifdef SSH_AUTH_SOCK
SSH_AUTH_SOCK_REAL := $(shell realpath "$(SSH_AUTH_SOCK)" 2>/dev/null)
ifneq ($(SSH_AUTH_SOCK_REAL),)
SSH_AGENT_OPTS := --volume "$(SSH_AUTH_SOCK_REAL):/tmp/ssh_auth_sock:ro" \
                  -e "SSH_AUTH_SOCK=/tmp/ssh_auth_sock"
else
SSH_AGENT_OPTS :=
endif
else
SSH_AGENT_OPTS :=
endif

# --- Mount options per operational mode ---
STANDARD_MOUNTS = \
    --mount type=tmpfs,destination=/home/$(DEV_USER) \
    --mount type=tmpfs,destination=/workspace \
    --mount type=bind,source=$(HOST_TMP_DIR)/caches,destination=/home/$(DEV_USER)/.cache,Z

ZERO_LEAKAGE_MOUNTS = \
    --mount type=tmpfs,destination=/home/$(DEV_USER) \
    --mount type=tmpfs,destination=/workspace \
    --mount type=tmpfs,destination=/home/$(DEV_USER)/.cache

RESOURCE_SAVER_MOUNTS = \
    --mount type=bind,source=$(HOST_TMP_DIR)/home,destination=/home/$(DEV_USER),Z \
    --mount type=bind,source=$(HOST_TMP_DIR)/workspace,destination=/workspace,Z \
    --mount type=bind,source=$(HOST_TMP_DIR)/caches,destination=/home/$(DEV_USER)/.cache,Z

# --- Core Podman security and base options ---
# Notes on .git mount: writable (no :ro) so `git push origin HEAD:<branch>`
# from inside the container persists commits to the host's git history.
# Run `make pull` on the host after exiting to sync the working tree.
PODMAN_BASE_OPTS = \
    --rm \
    --name $(CONTAINER_NAME) \
    --detach \
    --userns=keep-id \
    --security-opt "label=disable" \
    --security-opt "no-new-privileges" \
    --cap-drop=ALL \
    --cap-add=CHOWN \
    --cap-add=DAC_OVERRIDE \
    --cap-add=FOWNER \
    --cap-add=NET_BIND_SERVICE \
    --cap-add=SYS_CHROOT \
    --cap-add=SETUID \
    --cap-add=SETGID \
    --read-only \
    --mount type=tmpfs,destination=/run \
    --mount type=tmpfs,destination=/tmp \
    --mount type=bind,source=$(CURDIR)/.git,destination=/icebox/.git,Z \
    --dns $(ICEBOX_DNS) \
    -e "ICEBOX_GIT_BRANCH=$(shell git -C "$(CURDIR)" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

.PHONY: all icebox _icebox_start build down clean pull ssh-config help test-setup test \
        _prune _check_podman _check_git _check_ssh_key _build_if_needed

## (default): Start the ICEbox container (same as `icebox`).
all: icebox

## icebox: Build image (if needed), start a fresh container, and show SSH config.
##         If the container is already running, show existing SSH config instead.
icebox: _check_podman _build_if_needed _check_ssh_key _check_git
	@if podman inspect $(CONTAINER_NAME) > /dev/null 2>&1; then \
		echo "==> ICEbox '$(CONTAINER_NAME)' is already running."; \
		$(MAKE) -f $(THIS_MAKEFILE) --no-print-directory ssh-config; \
	else \
		$(MAKE) -f $(THIS_MAKEFILE) --no-print-directory _icebox_start \
			MODE="$(MODE)" \
			SSH_KEY_PATH="$(SSH_KEY_PATH)" \
			DEV_USER="$(DEV_USER)" \
			IMAGE_NAME="$(IMAGE_NAME)" \
			ICEBOX_DNS="$(ICEBOX_DNS)" \
			ICEBOX_ENV_VARS="$(ICEBOX_ENV_VARS)"; \
	fi

_icebox_start: _prune
	@case "$(MODE)" in \
		standard|zero_leakage|resource_saver) ;; \
		*) echo "Error: Invalid MODE '$(MODE)'. Must be 'standard', 'zero_leakage', or 'resource_saver'."; exit 1 ;; \
	esac
	@echo "==> Starting ICEbox '$(CONTAINER_NAME)' in '$(MODE)' mode..."
	@case "$(MODE)" in standard|resource_saver) mkdir -p $(HOST_TMP_DIR)/caches ;; esac
	@case "$(MODE)" in resource_saver) mkdir -p $(HOST_TMP_DIR)/workspace $(HOST_TMP_DIR)/home ;; esac
	$(eval MOUNT_OPTS := $($(shell echo $(MODE) | tr '[:lower:]' '[:upper:]')_MOUNTS))
	$(eval SSH_PUB_KEY := $(shell cat $(SSH_KEY_PATH)))
	$(eval EXISTING_PORT := $(shell awk '/^Host /{f=($$2=="$(CONTAINER_NAME)")} f && /^[[:space:]]+Port[[:space:]]/{print $$2; f=0}' $(HOME)/.ssh/config 2>/dev/null))
	$(eval PUBLISH_OPT := $(if $(EXISTING_PORT),--publish $(EXISTING_PORT):22,--publish 22))
	@if [ -z "$(SSH_AUTH_SOCK)" ]; then \
		echo "Warning: SSH_AUTH_SOCK not set. SSH agent forwarding disabled."; \
		echo "         Outbound git push will require manual credential setup inside the container."; \
	fi
	podman run \
		$(PODMAN_BASE_OPTS) \
		$(PUBLISH_OPT) \
		$(MOUNT_OPTS) \
		$(SSH_AGENT_OPTS) \
		-e "ICEBOX_SSH_PUB_KEY=$(SSH_PUB_KEY)" \
		-e "DEV_USER=$(DEV_USER)" \
		$(ICEBOX_ENV_VARS) \
		$(IMAGE_NAME)
	@HEALTHY=0; \
	echo "==> Waiting for container to become healthy (max 10s)..."; \
	for i in $$(seq 1 10); do \
		if [ -n "$$(podman port $(CONTAINER_NAME) 22/tcp 2>/dev/null)" ]; then \
			HEALTHY=1; \
			break; \
		fi; \
		if ! podman inspect $(CONTAINER_NAME) > /dev/null 2>&1; then \
			echo "Error: Container '$(CONTAINER_NAME)' failed to start."; \
			echo "Run 'podman logs $(CONTAINER_NAME)' to debug."; \
			exit 1; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$HEALTHY" = "1" ]; then \
		echo "==> Container started."; \
	else \
		echo "Error: Health check timed out. Run 'podman logs $(CONTAINER_NAME)' to investigate."; \
		exit 1; \
	fi
	@$(MAKE) -f $(THIS_MAKEFILE) --no-print-directory ssh-config

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
		echo "==> Building ICEbox image from $(ICEBOX_DIR)..."; \
		podman build -t $(IMAGE_NAME) $(ICEBOX_DIR) && touch $(BUILD_STAMP); \
	else \
		echo "==> ICEbox image is up to date, skipping build."; \
	fi

## down: Stop the running ICEbox container.
down: _check_podman
	@echo "==> Stopping container '$(CONTAINER_NAME)'..."
	@podman stop $(CONTAINER_NAME) > /dev/null 2>&1 || true

## clean: Stop container and delete all host cache artifacts.
clean: _prune
	@echo "==> Cleaning up container and all artifacts..."
	@echo "==> Deleting host cache directory..."
	@rm -rf $(HOST_TMP_DIR)
	@echo "==> Cleanup complete."

## pull: Sync the host working tree after pushing commits from inside the container.
##       Workflow: (in container) git commit && git push origin HEAD:<branch>
##                 (on host)      make pull
pull:
	@echo "==> Syncing host working tree to latest commit..."
	@if ! git -C "$(CURDIR)" diff --quiet 2>/dev/null || \
	   git -C "$(CURDIR)" diff --cached --name-only --diff-filter=MA 2>/dev/null | grep -q .; then \
		echo "Error: Host has modified or staged changes. Commit or stash them first."; \
		exit 1; \
	fi
	@git -C "$(CURDIR)" reset --hard HEAD
	@echo "==> Done. Working tree is up to date."

## ssh-config: Show and auto-update ~/.ssh/config for VS Code / terminal access.
ssh-config: _check_podman
	@PORT=$$(podman port $(CONTAINER_NAME) 22/tcp | cut -d: -f2); \
	if [ -z "$$PORT" ]; then \
		echo "Error: Container '$(CONTAINER_NAME)' is not running or SSH port not available."; \
		exit 1; \
	fi; \
	KEY_FILE=$(firstword $(subst .pub,,$(SSH_KEY_PATH))); \
	SNIPPET="Host $(CONTAINER_NAME)\n  HostName localhost\n  User $(DEV_USER)\n  Port $$PORT\n  IdentityFile $$KEY_FILE"; \
	SSH_CONFIG="$(HOME)/.ssh/config"; \
	touch "$$SSH_CONFIG" && chmod 600 "$$SSH_CONFIG"; \
	awk -v host="$(CONTAINER_NAME)" ' \
		/^[^[:space:]#]/ { in_block = (/^Host[[:space:]]/ && $$2 == host) } \
		!in_block { print } \
	' "$$SSH_CONFIG" > "$$SSH_CONFIG.icebox.tmp" && mv "$$SSH_CONFIG.icebox.tmp" "$$SSH_CONFIG"; \
	printf "\n$$SNIPPET\n" >> "$$SSH_CONFIG"; \
	echo ""; \
	echo "==> Updated ~/.ssh/config for Host $(CONTAINER_NAME) (port $$PORT)."; \
	echo ""; \
	echo "SSH access:"; \
	echo "  ssh $(CONTAINER_NAME)"; \
	echo "  code --remote ssh-remote+$(CONTAINER_NAME) /workspace"

## help: Show available targets.
help:
	@echo "ICEbox targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(THIS_MAKEFILE) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## test-setup: Initialize BATS testing submodules.
test-setup:
	@echo "==> Setting up testing dependencies..."
	@mkdir -p test_helper
	@if ! grep -q 'path = test_helper/bats-support' .gitmodules >/dev/null 2>&1; then \
		echo "--> Adding bats-support submodule..."; \
		git submodule add https://github.com/bats-core/bats-support test_helper/bats-support; \
	fi
	@if ! grep -q 'path = test_helper/bats-assert' .gitmodules >/dev/null 2>&1; then \
		echo "--> Adding bats-assert submodule..."; \
		git submodule add https://github.com/bats-core/bats-assert test_helper/bats-assert; \
	fi
	@git submodule update --init --recursive
	@echo "==> Test setup complete."

## test: Run the BATS test suite.
test:
	@echo "==> Running ICEbox test suite..."
	@if ! command -v bats &> /dev/null; then \
		echo "Error: bats not found. Install with 'sudo apt install bats'."; \
		exit 1; \
	fi
	bats test_icebox.bats

# --- Internal helpers ---

_prune:
	@echo "==> Pruning existing container instance..."
	@podman stop $(CONTAINER_NAME) > /dev/null 2>&1 || true
	@podman rm $(CONTAINER_NAME) > /dev/null 2>&1 || true

_check_podman:
	@if ! command -v podman &> /dev/null; then \
		echo "Error: podman not found. Please install it (https://podman.io/getting-started/installation)."; \
		exit 1; \
	fi

_check_git:
	@if [ ! -d "$(CURDIR)/.git" ]; then \
		echo "Error: No .git directory found. Run icebox from a git repository root."; \
		exit 1; \
	fi

_check_ssh_key:
	@if [ -z "$(SSH_KEY_PATH)" ]; then \
		echo "Error: No SSH public key found in ~/.ssh/. Generate one with 'ssh-keygen -t ed25519'."; \
		exit 1; \
	fi
	@if [ ! -f "$(SSH_KEY_PATH)" ]; then \
		echo "Error: SSH key not found at: $(SSH_KEY_PATH)"; \
		exit 1; \
	fi
