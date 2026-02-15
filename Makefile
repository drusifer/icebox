# ==============================================================================
# ICEbox: In-memory Containerized Environment
#
# This Makefile provides a secure, ephemeral, and containerized development
# environment managed by Podman.
# ==============================================================================

# --- Configuration ---
# Use bash for more advanced shell features
SHELL := /bin/bash

# Project-specific names derived from the current directory
PROJECT_NAME   := $(shell basename "$(PWD)")
CONTAINER_NAME := icebox-$(PROJECT_NAME)

# The container image. Built locally from the Dockerfile.
IMAGE_NAME ?= localhost/icebox:latest

# --- Auto-detect SSH Key ---
# Find the first available public SSH key. The user can override this by setting SSH_KEY_PATH.
FIRST_AVAILABLE_SSH_KEY := $(shell find $(HOME)/.ssh/id_*.pub -type f -print -quit)

# --- User-configurable Overrides ---
# MODE: Can be 'standard', 'zero_leakage', or 'resource_saver'.
MODE ?= standard
# SSH_KEY_PATH: Path to the public SSH key for container access. Auto-detects if not set.
SSH_KEY_PATH ?= $(FIRST_AVAILABLE_SSH_KEY)
# DEV_USER: The non-root user inside the container. Must exist in the base image.
DEV_USER ?= vscode
# ICEBOX_ENV_VARS: Pass additional environment variables to the container.
# Example: make up ICEBOX_ENV_VARS="-e MY_VAR=foo -e MY_SECRET=bar"
ICEBOX_ENV_VARS ?=

# Host directory for disk-backed caches and workspaces.
HOST_TMP_DIR := /var/tmp/icebox/$(PROJECT_NAME)

# --- Podman Mount Options for Operational Modes ---
# Standard Mode (Default): Workspace and home in memory, caches on disk.
STANDARD_MOUNTS = --mount type=tmpfs,destination=/home/$(DEV_USER) \
                  --mount type=tmpfs,destination=/workspace \
                  --mount type=bind,source=$(HOST_TMP_DIR)/caches,destination=/home/$(DEV_USER)/.cache,Z

# Zero Leakage Mode: Everything in memory, no disk writes.
ZERO_LEAKAGE_MOUNTS = --mount type=tmpfs,destination=/home/$(DEV_USER) \
                      --mount type=tmpfs,destination=/workspace \
                      --mount type=tmpfs,destination=/home/$(DEV_USER)/.cache

# Resource Saver Mode: Workspace and caches on disk to save RAM.
RESOURCE_SAVER_MOUNTS = --mount type=bind,source=$(HOST_TMP_DIR)/home,destination=/home/$(DEV_USER),Z \
                        --mount type=bind,source=$(HOST_TMP_DIR)/workspace,destination=/workspace,Z \
                        --mount type=bind,source=$(HOST_TMP_DIR)/caches,destination=/home/$(DEV_USER)/.cache,Z
# --- Core Podman Security and Base Options ---
PODMAN_BASE_OPTS = --rm \
                   --name $(CONTAINER_NAME) \
                   --detach \
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
                   --mount type=bind,source=$(PWD)/entrypoint.sh,destination=/usr/local/bin/entrypoint.sh,ro,Z \
                   --publish 22 \
                   --entrypoint /usr/local/bin/entrypoint.sh

.PHONY: all build up down clean ssh-config help test-setup test _prune

all: help

## build: Builds the ICEbox container image from the Dockerfile.
build: _check_podman
	@echo "==> Building ICEbox image..."
	podman build -t $(IMAGE_NAME) .

## up: Creates a fresh container, starts it, and shows SSH config.
up: build _check_ssh_key _prune
	@case "$(MODE)" in \
		standard|zero_leakage|resource_saver) \
			;; \
		*) \
			echo "Error: Invalid MODE '$(MODE)'. Must be one of 'standard', 'zero_leakage', or 'resource_saver'."; \
			exit 1; \
			;; \
	esac
	@echo "==> Starting ICEbox container '$(CONTAINER_NAME)' in '$(MODE)' mode..."
	@# Create host directories if needed for standard or resource_saver modes
	@case "$(MODE)" in standard|resource_saver) mkdir -p $(HOST_TMP_DIR)/caches;; esac
	@case "$(MODE)" in resource_saver) mkdir -p $(HOST_TMP_DIR)/workspace $(HOST_TMP_DIR)/home;; esac
	@# Select mount options based on mode
	$(eval MOUNT_OPTS := $($(shell echo $(MODE) | tr '[:lower:]' '[:upper:]')_MOUNTS))
	@# Ensure the entrypoint script is executable to prevent OCI permission errors.
	@chmod +x entrypoint.sh
	@# Read SSH public key content
	$(eval SSH_PUB_KEY := $(shell cat $(SSH_KEY_PATH)))
	podman run \
		$(PODMAN_BASE_OPTS) \
		$(MOUNT_OPTS) \
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
			echo "Error: Container '$(CONTAINER_NAME)' failed to start. It may have exited prematurely."; \
			echo "To debug, remove the '--rm' flag from PODMAN_BASE_OPTS in the Makefile, run 'make up', and then check 'podman logs $(CONTAINER_NAME)'."; \
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
	@$(MAKE) --no-print-directory ssh-config

## down: Stops the running ICEbox container.
down: _check_podman
	@echo "==> Stopping container '$(CONTAINER_NAME)'..."
	@podman stop $(CONTAINER_NAME) > /dev/null 2>&1 || true

## clean: Stops, removes container, and deletes all host artifacts (caches).
clean: _prune
	@echo "==> Deleting host cache directory..."
	@rm -rf $(HOST_TMP_DIR)
	@echo "==> Cleanup complete."

## ssh-config: Generates the SSH configuration for VS Code.
ssh-config: _check_podman
	@echo "==> Generating SSH config for VS Code..."
	@PORT=$$(podman port $(CONTAINER_NAME) 22/tcp | cut -d: -f2); \
	if [ -z "$$PORT" ]; then \
		echo "Error: Container not running or port not published."; \
		exit 1; \
	fi; \
	echo ""; \
	echo "Add the following to your ~/.ssh/config file:"; \
	echo "-------------------------------------------------"; \
	echo "Host $(CONTAINER_NAME)"; \
	echo "  HostName localhost"; \
	echo "  User $(DEV_USER)"; \
	echo "  Port $$PORT"; \
	echo "  # Ensure this points to the private key corresponding to the public key used"; \
	echo "  IdentityFile $(firstword $(subst .pub,,$(SSH_KEY_PATH)))"; \
	echo "-------------------------------------------------"

## help: Shows this help message.
help:
	@echo "ICEbox Makefile Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## test-setup: Installs testing dependencies using git submodules.
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
	@echo "==> Initializing and updating submodules..."
	@git submodule update --init --recursive
	@echo "==> Test setup complete."

## test: Runs the bats test suite.
test:
	@echo "==> Running ICEbox test suite..."
	@if ! command -v bats &> /dev/null; then \
		echo "Error: bats-core could not be found. Please install it (e.g., 'sudo apt install bats')."; \
		exit 1; \
	fi
	bats test_icebox.bats

# --- Helper Targets (not intended for direct use) ---
_prune:
	@echo "==> Pruning existing container instance..."
	@podman stop $(CONTAINER_NAME) > /dev/null 2>&1 || true
	@podman rm $(CONTAINER_NAME) > /dev/null 2>&1 || true

_check_podman:
	@if ! command -v podman &> /dev/null; then \
		echo "Error: podman could not be found. Please install it."; \
		exit 1; \
	fi

_check_git:
	@if [ ! -d ".git" ]; then \
		echo "Error: .git directory not found. This command must be run from the project root."; \
		exit 1; \
	fi

_check_ssh_key:
	@if [ -z "$(SSH_KEY_PATH)" ]; then \
		echo "Error: Could not auto-detect a public SSH key in ~/.ssh/ (e.g., id_ed25519.pub, id_rsa.pub)."; \
		echo "Please generate one with 'ssh-keygen -t ed25519' or specify a path manually:"; \
		echo "  make up SSH_KEY_PATH=/path/to/your/key.pub"; \
		exit 1; \
	fi
	@if [ ! -f "$(SSH_KEY_PATH)" ]; then \
		echo "Error: SSH key not found at specified path: '$(SSH_KEY_PATH)'."; \
		exit 1; \
	fi