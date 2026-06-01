#!/usr/bin/env bash
set -euo pipefail
FILE="/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/results/spine-failure_ch-off_maglev-off.json"
ft=$(jq '[.flows[].established_at | select(. != null and . > 0)] | max + 5' "$FILE")
echo "inferred failtime: $ft"
tmp=$(mktemp)
jq --argjson ft "$ft" '.summary.failtime = $ft' "$FILE" > "$tmp" && mv "$tmp" "$FILE"
echo "patched. failtime in JSON:"
jq '.summary.failtime' "$FILE"
