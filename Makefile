# Build the Icarus dedicated server image.
#
#   make build                                  # auto-detect engine, latest DepotDownloader
#   make build DEPOTDOWNLOADER_VERSION=3.3.0    # pin the downloader
#   make build ENGINE=docker TAG=v1             # force engine and tag
#
# Every variable below can be overridden on the command line or from the
# environment; nothing here is resolved unless a target actually needs it.

# Builds to a plain local tag by default. To build for a registry, give the
# fully qualified name, which is also what `make push` will use:
#   make build IMAGE=registry.example.com/you/icarus TAG=v1
#   make push  IMAGE=registry.example.com/you/icarus TAG=v1
IMAGE    ?= icarus-server
TAG      ?= dev
PLATFORM ?= linux/amd64

# Leave empty to use the Dockerfile's own default base. Set it to trial another,
# e.g. BASE_IMAGE=dhi.io/debian-base:trixie-debian13-dev (needs a DHI login).
BASE_IMAGE ?=

# WineHQ package version to pin; empty uses the Dockerfile's default.
WINE_VERSION ?=

# --- container engine -------------------------------------------------------
# Auto-detected only when the caller has not chosen one. podman wins when both
# are installed, because that is what the build machines here run.
ifeq ($(origin ENGINE), undefined)
ENGINE := $(shell for e in podman docker; do command -v $$e >/dev/null 2>&1 && { echo $$e; break; }; done)
endif

# podman defaults to the OCI image format, which silently discards the
# Dockerfile's HEALTHCHECK. docker build has no such flag and needs none.
ifeq ($(ENGINE),podman)
ENGINE_FLAGS := --format docker
else
ENGINE_FLAGS :=
endif

# --- DepotDownloader version ------------------------------------------------
# Resolved lazily: the API is only queried by targets that reference it, so
# `make help` and `make clean` stay offline. An explicit override skips it.
DD_RELEASES_API := https://api.github.com/repos/SteamRE/DepotDownloader/releases/latest
ifeq ($(origin DEPOTDOWNLOADER_VERSION), undefined)
DEPOTDOWNLOADER_VERSION = $(shell curl -fsSL --max-time 20 $(DD_RELEASES_API) \
    | sed -n 's/.*"tag_name": *"DepotDownloader_\([^"]*\)".*/\1/p' | head -1)
endif

BUILD_ARGS := --network=host --platform=$(PLATFORM) $(ENGINE_FLAGS) \
	$(if $(BASE_IMAGE),--build-arg BASE_IMAGE=$(BASE_IMAGE),) \
	$(if $(WINE_VERSION),--build-arg WINE_VERSION=$(WINE_VERSION),)

.PHONY: help build push smoke lint version clean check-engine

help: ## Show this help
	@echo "Targets:"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'
	@echo
	@echo "Variables (current value):"
	@echo "  IMAGE          $(IMAGE)"
	@echo "  TAG            $(TAG)"
	@echo "  PLATFORM       $(PLATFORM)"
	@echo "  BASE_IMAGE     $(if $(BASE_IMAGE),$(BASE_IMAGE),<Dockerfile default>)"
	@echo "  WINE_VERSION   $(if $(WINE_VERSION),$(WINE_VERSION),<Dockerfile default>)"
	@echo "  ENGINE         $(if $(ENGINE),$(ENGINE),<none found>)"
	@echo "  DEPOTDOWNLOADER_VERSION  (latest from GitHub unless overridden)"

check-engine:
	@test -n "$(ENGINE)" || { \
	  echo "error: neither podman nor docker found on PATH." >&2; \
	  echo "       install one, or pass ENGINE=<name>." >&2; exit 1; }
	@command -v $(ENGINE) >/dev/null 2>&1 || { \
	  echo "error: ENGINE=$(ENGINE) is not on PATH." >&2; exit 1; }

version: check-engine ## Print the engine and DepotDownloader version that would be used
	@v='$(DEPOTDOWNLOADER_VERSION)'; \
	test -n "$$v" || { echo "error: could not resolve the latest DepotDownloader version." >&2; \
	  echo "       check network access, or pass DEPOTDOWNLOADER_VERSION=x.y.z." >&2; exit 1; }; \
	echo "engine:          $(ENGINE)"; \
	echo "image:           $(IMAGE):$(TAG)"; \
	echo "DepotDownloader: $$v"

build: check-engine ## Build the image
	@v='$(DEPOTDOWNLOADER_VERSION)'; \
	test -n "$$v" || { echo "error: could not resolve the latest DepotDownloader version." >&2; \
	  echo "       check network access, or pass DEPOTDOWNLOADER_VERSION=x.y.z." >&2; exit 1; }; \
	echo "==> $(ENGINE) build $(IMAGE):$(TAG) (DepotDownloader $$v$(if $(BASE_IMAGE), on $(BASE_IMAGE),))"; \
	$(ENGINE) build $(BUILD_ARGS) \
	  --build-arg DEPOTDOWNLOADER_VERSION="$$v" \
	  -t $(IMAGE):$(TAG) .

push: check-engine ## Push the built image
	$(ENGINE) push $(IMAGE):$(TAG)

smoke: check-engine ## Exercise the entrypoint end to end without downloading the game
	@echo "==> $(IMAGE):$(TAG) with UPDATE_ON_START=false"
	@out=$$($(ENGINE) run --rm --network=host \
	    -e UID=1000 -e GID=1000 -e UPDATE_ON_START=false \
	    $(IMAGE):$(TAG) 2>&1); \
	printf '%s\n' "$$out"; \
	if printf '%s' "$$out" | grep -q 'Server executable missing'; then \
	  echo "==> PASS: entrypoint reached the executable check (nothing installed, as expected)"; \
	else \
	  echo "==> FAIL: entrypoint did not get as far as the executable check" >&2; exit 1; \
	fi

lint: ## Syntax-check the shell scripts
	bash -n scripts/*.sh
	@command -v shellcheck >/dev/null 2>&1 \
	  && shellcheck scripts/*.sh \
	  || echo "shellcheck not installed, skipped"

clean: check-engine ## Remove the locally built image
	-$(ENGINE) rmi $(IMAGE):$(TAG)
