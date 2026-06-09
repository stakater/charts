#!/usr/bin/env bash
#
# fetch-cluster-metrics.sh — capture real /metrics from YOUR running Crossplane so the
# chart's referenced metrics can be verified against your environment (not just docs).
#
# Run it against any cluster you have `kubectl` access to. It scrapes the Crossplane core
# and every provider pod, records component versions, and bundles everything into a folder
# (and a .tgz) you can hand back for validation with tests/verify-fetched.py.
#
#   ./tests/fetch-cluster-metrics.sh                       # ns = crossplane-system
#   ./tests/fetch-cluster-metrics.sh -n my-crossplane-ns   # custom namespace
#   ./tests/fetch-cluster-metrics.sh --out /tmp/cluster-a  # output dir
#
# Requires: kubectl, curl. Read-only against the cluster (port-forward + curl /metrics).
set -euo pipefail
NS="crossplane-system"
OUT=""
PORT=8080
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
OUT="${OUT:-./fetched-metrics-${CTX//[^a-zA-Z0-9_.-]/_}}"
mkdir -p "$OUT"
echo ">> context: $CTX   namespace: $NS   ->  $OUT"

scrape() { # <target> <dest>
  echo "   scraping $1"
  kubectl -n "$NS" port-forward "$1" "${PORT}:${PORT}" >/dev/null 2>&1 &
  local pf=$!; sleep 4
  curl -sf "localhost:${PORT}/metrics" > "$2" 2>/dev/null || echo "   WARN: scrape failed for $1 (wrong port? metrics disabled?)" >&2
  kill "$pf" 2>/dev/null || true
}

# 1. versions / inventory — so we know exactly what build this came from
{
  echo "# context: $CTX"; echo "# namespace: $NS"; echo "# captured: $(date -u +%FT%TZ)"
  echo "## crossplane deployment image:"
  kubectl -n "$NS" get deploy crossplane -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null; echo
  echo "## providers:"; kubectl get providers.pkg.crossplane.io -o custom-columns=NAME:.metadata.name,PKG:.spec.package 2>/dev/null || true
  echo "## functions:"; kubectl get functions.pkg.crossplane.io -o custom-columns=NAME:.metadata.name,PKG:.spec.package 2>/dev/null || true
} > "${OUT}/INVENTORY.txt"

# 2. crossplane core (controller-runtime, workqueue, function_run_*, circuit_breaker_*)
# Auto-discover the core: prefer deploy/crossplane, else a pod labelled app=crossplane.
CORE_TARGET="deploy/crossplane"
if ! kubectl -n "$NS" get deploy crossplane >/dev/null 2>&1; then
  CORE_POD="$(kubectl -n "$NS" get pods -l app=crossplane -o name 2>/dev/null | head -1)"
  [ -n "$CORE_POD" ] && CORE_TARGET="$CORE_POD" || echo "   WARN: could not find crossplane core (deploy/crossplane or app=crossplane) in $NS" >&2
fi
scrape "$CORE_TARGET" "${OUT}/core-metrics.txt"

# 3. every provider pod (crossplane_managed_resource_*, upjet_* on Upjet providers)
for p in $(kubectl -n "$NS" get pods -l pkg.crossplane.io/provider -o name 2>/dev/null); do
  name="$(basename "$p")"
  scrape "$p" "${OUT}/provider-${name}.txt"
done

# 4. platform metrics live elsewhere — emit the queries to run against your Prometheus/Thanos
cat > "${OUT}/PLATFORM-QUERIES.md" <<'EOF'
# Platform metrics (NOT on Crossplane endpoints)

These are referenced by the footprint / API alerts but come from kube-apiserver, cAdvisor,
and kube-state-metrics. Easiest to confirm by running these instant queries in your
Prometheus / Thanos / OpenShift "Observe → Metrics" and pasting the output back. A non-empty
result confirms the metric exists with the labels the rules use.

- aggregator_unavailable_apiservice{name=~".*crossplane.*"}
- container_memory_working_set_bytes{pod=~"provider.*", container!=""}
- container_cpu_cfs_throttled_periods_total{pod=~"provider.*"}
- container_cpu_cfs_periods_total{pod=~"provider.*"}
- kube_pod_container_status_restarts_total{namespace="crossplane-system"}
- kube_pod_container_status_last_terminated_reason{namespace="crossplane-system"}

If you also run compositions with Functions / Upjet providers, confirm these (Crossplane core
/ Upjet provider — they should already be in the scraped dumps if exercised):

- function_run_function_response_total                 # expect a `result` label incl. "error"
- circuit_breaker_events_total                         # expect a `result` label incl. "Dropped"
- upjet_resource_ttr_bucket                            # confirm the histogram + its labels
- upjet_resource_reconcile_delay_seconds_bucket
EOF

tar -czf "${OUT}.tgz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null || true
echo ">> done."
echo ">> folder: $OUT"
echo ">> bundle: ${OUT}.tgz  (hand this back, or run: python3 tests/verify-fetched.py --dumps $OUT)"
