#!/usr/bin/env bash
#
# capture-metrics.sh — regenerate metrics-allowlist.txt from a REAL Crossplane build.
#
# This is the step that turns the allowlist from "seeded from docs" into ground truth.
# It reads the Prometheus text exposition from the core and provider /metrics endpoints,
# extracts the actual metric names, and writes them to the allowlist. After running it,
# check_metrics.py is genuinely validating against what the cluster emits.
#
# Two modes:
#   Offline (preferred for CI fixtures) — feed saved dumps:
#     ./capture-metrics.sh --core core-metrics.txt --provider provider-metrics.txt
#
#   Live — port-forward to the running pods and scrape them:
#     ./capture-metrics.sh --live --namespace crossplane-system \
#         --core-svc crossplane --provider-selector pkg.crossplane.io/provider
#
# Capture dumps by hand for the offline mode:
#   kubectl -n crossplane-system port-forward deploy/crossplane 8080:8080 &
#   curl -s localhost:8080/metrics > core-metrics.txt
#   (repeat for a provider pod's metrics port)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/metrics-allowlist.txt"
MODE=offline
NS=crossplane-system
CORE_SVC=crossplane
PROVIDER_SELECTOR="pkg.crossplane.io/provider"
CORE_FILE=""
PROVIDER_FILE=""
INVENTORY_FILE=""
PORT=8080

while [ $# -gt 0 ]; do
  case "$1" in
    --live) MODE=live; shift ;;
    --namespace) NS="$2"; shift 2 ;;
    --core) CORE_FILE="$2"; shift 2 ;;
    --provider) PROVIDER_FILE="$2"; shift 2 ;;
    --inventory) INVENTORY_FILE="$2"; shift 2 ;;
    --core-svc) CORE_SVC="$2"; shift 2 ;;
    --provider-selector) PROVIDER_SELECTOR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -o|--out) OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

scrape_live() {
  local target="$1" dest="$2"
  echo ">> scraping $target" >&2
  kubectl -n "$NS" port-forward "$target" "${PORT}:${PORT}" >/dev/null 2>&1 &
  local pf=$!
  sleep 3
  curl -sf "localhost:${PORT}/metrics" > "$dest" || { kill "$pf"; echo "scrape failed: $target" >&2; exit 1; }
  kill "$pf" 2>/dev/null || true
}

if [ "$MODE" = live ]; then
  scrape_live "svc/${CORE_SVC}" "${tmp}/core.txt"
  prov_pod="$(kubectl -n "$NS" get pods -l "$PROVIDER_SELECTOR" -o name | head -1)"
  [ -n "$prov_pod" ] && scrape_live "$prov_pod" "${tmp}/provider.txt" || echo "WARN: no provider pod matched $PROVIDER_SELECTOR" >&2
else
  [ -n "$CORE_FILE" ] && cp "$CORE_FILE" "${tmp}/core.txt"
  [ -n "$PROVIDER_FILE" ] && cp "$PROVIDER_FILE" "${tmp}/provider.txt"
  [ -n "$INVENTORY_FILE" ] && cp "$INVENTORY_FILE" "${tmp}/inventory.txt"
  if ! ls "${tmp}"/*.txt >/dev/null 2>&1; then
    echo "offline mode needs --core and/or --provider and/or --inventory <dump.txt>" >&2; exit 2
  fi
fi

# Extract metric names from the exposition format: the leading token of each sample line
# (so histograms yield x_bucket / x_sum / x_count as actually emitted). Comments dropped.
extract() { grep -hvE '^#' "$@" 2>/dev/null | sed -E 's/[ {].*$//' | grep -E '^[a-zA-Z_:][a-zA-Z0-9_:]*$' || true; }

{
  echo "# metrics-allowlist.txt — CAPTURED metric names from a real Crossplane build (see tests/fixtures/CAPTURE.md for the pinned versions)."
  echo "# Source endpoints: core=${CORE_SVC:-n/a} provider-selector=${PROVIDER_SELECTOR:-n/a} ns=${NS}"
  echo "# Regenerate with tests/capture-metrics.sh. check_metrics.py validates rules against this."
  echo "#"
  echo "# NOTE: this is the FULL emitted metric set. The chart only references a subset; that"
  echo "#       is fine — the gate only requires referenced metrics to be present here."
  echo
  # LC_ALL=C so the ordering is byte-collation, identical on every machine/CI runner —
  # otherwise a runner's default locale reorders punctuation (e.g. `_`) and the weekly
  # drift check sees phantom churn even when the metric name set is unchanged.
  extract "${tmp}"/*.txt | LC_ALL=C sort -u
} > "$OUT"

echo ">> wrote $(grep -cvE '^#|^$' "$OUT") metric names to $OUT" >&2
