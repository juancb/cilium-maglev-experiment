# Cilium Maglev × switch consistent-hashing lab.
#
# Run from Git Bash on Windows OR from inside WSL — the Makefile detects the context.
#  Git Bash:  make up / make test-failover   (routes through WSL automatically)
#  WSL root:  make up / make test-failover   (runs directly)

SHELL := /bin/bash
TOPO  := topo/clos.clab.yml

# ── WSL routing ───────────────────────────────────────────────────────────────
# Inside WSL, WSL_DISTRO_NAME is set. On Windows (Git Bash / PowerShell) it isn't.
# Git Bash exposes the repo as /c/Users/... — convert the drive-letter prefix to /mnt/X/.
ifdef WSL_DISTRO_NAME
  # Already inside WSL: run scripts directly
  _R   :=
  _DIR := $(CURDIR)
else
  # On Windows: forward through wsl.exe as root
  # MSYS_NO_PATHCONV=1 stops Git Bash from mangling the /mnt/... path.
  _R   := MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash
  _DIR := $(shell echo '$(CURDIR)' | sed 's|^/\([a-zA-Z]\)/|/mnt/\1/|')
endif

.PHONY: help images up down redeploy test test-fabric test-cilium \
        test-failover test-failover-node sweep status

help:
	@echo "Targets (run from Git Bash on Windows or from WSL root):"
	@echo "  images              build maglev/k3s-bird + maglev/client images"
	@echo "  up                  deploy topology, bootstrap k3s+Cilium(maglev), apply demo app"
	@echo "  down                destroy the topology"
	@echo "  redeploy            down + up"
	@echo "  test-fabric         Test 1 — fabric + consistent hashing"
	@echo "  test-cilium         Test 2 — Cilium mode + cross-node backend consistency"
	@echo "  test-failover       Test 3 — spine failure (default; baseline ~0%)"
	@echo "  test-failover-node  Test 3 — single-node failure (primary Maglev experiment)"
	@echo "  sweep               vary B (and M) → results/sweep.csv"
	@echo "  status              containerlab inspect"

images:
	$(_R) $(_DIR)/scripts/build-images.sh

up:
	@command -v wsl >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 \
	  || { echo "ERROR: neither wsl nor docker found"; exit 1; }
	$(_R) $(_DIR)/scripts/bring-up.sh

down:
	$(_R) $(_DIR)/scripts/tear-down.sh

redeploy: down up

test: test-fabric test-cilium test-failover

test-fabric:
	$(_R) $(_DIR)/tests/01-fabric.sh

test-cilium:
	$(_R) $(_DIR)/tests/02-cilium.sh

test-failover:
	$(_R) $(_DIR)/tests/03-failover.sh

test-failover-node:
	$(_R) $(_DIR)/tests/03-failover.sh --node-failure

sweep:
	$(_R) $(_DIR)/scripts/sweep.sh

status:
	MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- \
	  bash -c 'CLAB_VERSION_CHECK=disable containerlab inspect -t $(_DIR)/$(TOPO)'
