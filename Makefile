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
        test-maglev test-disruption verify-bgp apply-bgp status

help:
	@echo "Targets (run from Git Bash on Windows or from WSL root):"
	@echo "  images              build maglev/k3s-bird + maglev/client images"
	@echo "  up                  deploy topology, bootstrap k3s+Cilium(maglev), apply demo app"
	@echo "  down                destroy the topology"
	@echo "  redeploy            down + up"
	@echo "  test-fabric         Test 1 — fabric + consistent hashing"
	@echo "  test-cilium         Test 2 — Cilium mode + cross-node backend consistency"
	@echo "  test-maglev         Maglev paired test — 2x2 {maglev,random}x{dsr,snat}, one node-drain failure"
	@echo "  test-disruption     Test 5 — Cilium agent restart/kill + backend kill, maglev on/off, eTP/iTP"
	@echo "                      (env: ALGOS MODES POLICIES DISRUPTIONS TARGET_NODE UPGRADE_TO RUNS ...)"
	@echo "  verify-bgp          show negotiated hold timers + GR state of every node BGP session"
	@echo "  apply-bgp           push BGP timer config into a running lab (resets sessions once)"
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

test: test-fabric test-cilium test-maglev

test-fabric:
	$(_R) $(_DIR)/tests/01-fabric.sh

test-cilium:
	$(_R) $(_DIR)/tests/02-cilium.sh

test-maglev:
	$(_R) $(_DIR)/tests/04-maglev-matrix.sh

# Test 5 env knobs (ALGOS, POLICIES, DISRUPTIONS, ...) must cross the wsl.exe boundary:
# WSLENV only forwards listed variables, so pass them explicitly with env.
DZ_VARS := ALGOS MODES POLICIES DISRUPTIONS TARGET_NODE IC_NODE KILL_COUNT UPGRADE_TO \
           CILIUM_VERSION N RUNS REPLICAS PROBE_HZ DUR_ROLLOUT DUR_KILL DUR_DELETE SETTLE STRICT_BGP \
           FLOW_TIMEOUT MAX_UNAVAILABLE CAPTURE_PCAP CAPTURE_BGP RUN_LABEL SVC_COUNT ADVERTISE_CLUSTERIP
DZ_ENV  := $(foreach v,$(DZ_VARS),$(if $($(v)),$(v)='$($(v))'))

test-disruption:
	$(if $(_R),$(_R) -c "env $(DZ_ENV) bash $(_DIR)/tests/05-cilium-disruption.sh",bash $(_DIR)/tests/05-cilium-disruption.sh)

verify-bgp:
	$(_R) $(_DIR)/tests/lib/bgp-verify.sh

apply-bgp:
	$(_R) $(_DIR)/scripts/apply-bgp-config.sh

status:
	MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- \
	  bash -c 'DOCKER_HOST=unix:///var/run/docker-native.sock CLAB_VERSION_CHECK=disable containerlab inspect -t $(_DIR)/$(TOPO)'
