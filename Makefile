.PHONY: all clean deep-clean base claude-code openai-codex open-code base-v2 open-code-v2

# Determine container engine (podman or docker)
CONTAINER_ENGINE := $(shell which podman 2>/dev/null || which docker 2>/dev/null)

# UID/GID of the in-container 'node' user. Defaults to the builder's, so
# bind-mounted host dirs are writable. Override: make open-code HOST_UID=1000
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)

# Note: the apt tool list lives in base/Dockerfile (LOCAL_TOOLS ARG), which is
# the single source of truth. Add tools there, not here.

# Ensure we have a container engine
ifeq ($(CONTAINER_ENGINE),)
$(error No container engine (podman/docker) found in PATH)
endif

all: base claude-code openai-codex

base:
	@echo "Building base image"
	$(CONTAINER_ENGINE) build \
		--build-arg HOST_UID=$(HOST_UID) \
		--build-arg HOST_GID=$(HOST_GID) \
		-t agent-base \
		-f base/Dockerfile base

claude-code: base
	@echo "Building claude-code"
	$(CONTAINER_ENGINE) build \
		--no-cache \
		-t claude-code \
		-f claude-code/Dockerfile claude-code

openai-codex: base
	@echo "Building openai-codex"
	$(CONTAINER_ENGINE) build \
		--no-cache \
		-t openai-codex \
		-f openai-codex/Dockerfile openai-codex

open-code: base
	@echo "Building open-code"
	$(CONTAINER_ENGINE) build \
		--no-cache \
		-t open-code \
		-f open-code/Dockerfile open-code

# v2: user-agnostic images (runtime user created by base/entrypoint.sh).
# Never tags `latest`/`open-code`, so the v1 setup (open-code:v1) is unaffected.
base-v2:
	@echo "Building base image v2"
	$(CONTAINER_ENGINE) build \
		--pull \
		-t agent-base:v2 \
		-f base/Dockerfile.v2 base

open-code-v2: base-v2
	@echo "Building open-code v2"
	$(CONTAINER_ENGINE) build \
		--no-cache \
		-t open-code:v2 \
		-f open-code/Dockerfile.v2 open-code

clean:
	@echo "Removing container images"
	@for image in open-code claude-code openai-codex agent-base open-code:v2 agent-base:v2; do \
		if $(CONTAINER_ENGINE) image inspect $$image > /dev/null 2>&1; then \
			echo "Removing $$image"; \
			$(CONTAINER_ENGINE) rmi -f $$image; \
		else \
			echo "Image $$image does not exist, skipping"; \
		fi; \
	done
