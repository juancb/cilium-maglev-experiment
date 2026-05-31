#!/usr/bin/env bash
# Sweep the backend count B and emit broken-flow fractions per 2×2 cell to results/sweep.csv,
# alongside the closed-form prediction broken ≈ D·((M-1)/M)·((B-1)/B), D≈N/P (CH on) or 2N/3
# (CH off), so you can plot measured-vs-predicted.
#
# Reuses tests/03-failover.sh (which writes results/<tag>.json per cell). Slow: it runs the
# full 2×2 for each B. Override the B list with: BLIST="2 4 8" N=400 ./scripts/sweep.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/common.sh

BLIST="${BLIST:-2 4 6 8}"
N="${N:-300}"
P=3; M=3
CSV="${RESULTS_DIR}/sweep.csv"
echo "B,N,cell,broken,established,pct_measured,pct_predicted" > "$CSV"

pct_pred() {  # args: D_factor B  -> predicted percent of established flows broken
  local Df="$1" B="$2"
  awk -v Df="$Df" -v B="$B" -v M="$M" 'BEGIN{ printf "%.1f", 100*Df*((M-1)/M)*((B-1)/B) }'
}

for B in $BLIST; do
  info "sweep: B=${B}"
  B="$B" N="$N" bash tests/03-failover.sh || true
  for tag in ch-off_maglev-off ch-on_maglev-off ch-off_maglev-on ch-on_maglev-on; do
    f="${RESULTS_DIR}/${tag}.json"
    [ -s "$f" ] || continue
    broken=$(jq '[.flows[] | select(.status=="broken" and .established_at!=null)] | length' "$f")
    est=$(jq '.summary.established' "$f")
    pctm=$(awk -v b="$broken" -v e="$est" 'BEGIN{ if(e>0) printf "%.1f", 100*b/e; else print "0" }')
    # prediction: Maglev on => ~0; Maglev off => D-factor 1/P (CH on) or 2/3 (CH off)
    case "$tag" in
      *maglev-on*)  pctp="0.0" ;;
      ch-on_maglev-off)  pctp=$(pct_pred "$(awk -v P=$P 'BEGIN{print 1/P}')" "$B") ;;
      ch-off_maglev-off) pctp=$(pct_pred "0.6667" "$B") ;;
    esac
    echo "${B},${N},${tag},${broken},${est},${pctm},${pctp}" >> "$CSV"
  done
done

green "sweep complete → ${CSV}"
column -s, -t "$CSV" || cat "$CSV"
