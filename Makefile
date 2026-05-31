# Cilium Maglev × switch consistent-hashing lab. Run from WSL2/Linux.
# Most targets shell out to containerlab (needs sudo) + docker.

SHELL := /bin/bash
TOPO  := topo/clos.clab.yml

.PHONY: help images up down redeploy test test-fabric test-cilium test-failover sweep status

help:
	@echo "Targets:"
	@echo "  images        build maglev/k3s-bird + maglev/client images"
	@echo "  up            deploy topology, bootstrap k3s+Cilium(maglev), apply demo app"
	@echo "  down          destroy the topology"
	@echo "  redeploy      down + up"
	@echo "  test-fabric   Test 1 — fabric + consistent hashing"
	@echo "  test-cilium   Test 2 — Cilium mode + cross-node backend consistency"
	@echo "  test-failover Test 3 — the 2x2 broken-flow matrix"
	@echo "  sweep         vary B (and M) -> results/sweep.csv"
	@echo "  status        containerlab inspect"

images:
	docker build -t maglev/k3s-bird:latest nodes/
	docker build -t maglev/client:latest   tests/lib/flowgen/

up:
	@command -v containerlab >/dev/null || { echo "install containerlab first"; exit 1; }
	@docker image inspect maglev/k3s-bird:latest >/dev/null 2>&1 || $(MAKE) images
	bash scripts/bring-up.sh

down:
	bash scripts/tear-down.sh

redeploy: down up

test: test-fabric test-cilium test-failover

test-fabric:
	bash tests/01-fabric.sh

test-cilium:
	bash tests/02-cilium.sh

test-failover:
	bash tests/03-failover.sh

sweep:
	bash scripts/sweep.sh

status:
	CLAB_VERSION_CHECK=disable containerlab inspect -t $(TOPO)
