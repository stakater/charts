#!/usr/bin/env bash
#
# capture.sh — scrape every MetalLB metrics endpoint on the running e2e stack into
# tests/fixtures/*-metrics.txt, and print the scrape-surface facts the roadmap needs
# (ports, container names, operator-created monitors). Read-only against the cluster.
# Run up.sh first. Afterwards: ../generate-allowlist.sh && revise ../../docs/roadmap.md.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
FIX="${E2E}/../fixtures"
mkdir -p "$FIX"

# capture <fixture-name> <pod> <port>: scrape one endpoint.
# Tries the API-server pod proxy first (dials the POD IP — reaches the speaker, which
# binds its metrics to the node IP under hostNetwork); falls back to port-forward
# (dials localhost in the pod's netns — reaches frr-k8s's 127.0.0.1-bound raw ports).
capture() {
  local name="$1" pod="$2" port="$3" lp pf out
  out="${FIX}/${name}-metrics.txt"
  if k get --raw "/api/v1/namespaces/${NS}/pods/${pod}:${port}/proxy/metrics" > "$out" 2>/dev/null && [ -s "$out" ]; then
    green "  ${name}-metrics.txt  <- ${pod}:${port} (api proxy)  ($(grep -cv '^#' "$out") series, $(grep -c '^# TYPE' "$out") families)"
    return 0
  fi
  lp=$(( 20000 + RANDOM % 10000 ))
  k -n "$NS" port-forward "pod/${pod}" "${lp}:${port}" >/dev/null 2>&1 & pf=$!
  for _ in $(seq 1 20); do curl -sf "http://localhost:${lp}/metrics" > "$out" 2>/dev/null && break; sleep 1; done
  kill $pf 2>/dev/null || true
  [ -s "$out" ] || { red "FAILED to scrape ${pod}:${port}"; return 1; }
  green "  ${name}-metrics.txt  <- ${pod}:${port} (port-forward)  ($(grep -cv '^#' "$out") series, $(grep -c '^# TYPE' "$out") families)"
}

step "1. pods and their declared container ports (the scrape surface)"
k -n "$NS" get pods -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name' --no-headers
k -n "$NS" get pods -o json | jq -r '
  .items[] | .metadata.name as $p | .spec.containers[] | .name as $c
  | (.ports // [])[] | "\($p)\t\($c)\t\(.name // "-")\t\(.containerPort)"' | sort -u | column -t

step "2. scrape controller, EVERY speaker, one frr-k8s pod"
CONTROLLER="$(k -n "$NS" get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')"
FRRK8S="$(k -n "$NS" get pods -o name | grep -m1 frr-k8s | cut -d/ -f2 || true)"

capture controller "$CONTROLLER" 7472
# metallb_layer2_* and metallb_speaker_announced register LAZILY and only on the
# speaker currently announcing a service — one arbitrary speaker misses them.
# Capture every speaker and commit the union as one fixture, separated by comments.
: > "${FIX}/speaker-metrics.txt"
for SP in $(k -n "$NS" get pods -l app.kubernetes.io/component=speaker -o jsonpath='{.items[*].metadata.name}'); do
  capture "speaker-${SP##*-}" "$SP" 7472
  { echo "# --- pod: ${SP}"; cat "${FIX}/speaker-${SP##*-}-metrics.txt"; } >> "${FIX}/speaker-metrics.txt"
  rm "${FIX}/speaker-${SP##*-}-metrics.txt"
done
green "  speaker-metrics.txt     <- union of all speakers ($(grep -cv '^#' "${FIX}/speaker-metrics.txt") series)"
if [ -n "$FRRK8S" ]; then
  # frr-k8s binds its RAW metrics to 127.0.0.1 only (controller: 7572, frr translator:
  # 7573 — subchart values) and exposes them externally ONLY via kube-rbac-proxy TLS
  # ports (9140/9141, container ports named "metricshttps"). kubectl port-forward
  # reaches 127.0.0.1-bound ports, so the raw ports serve the fixture; the TLS surface
  # is what a real monitor must scrape (bearer token + TLS) — recorded in README.
  capture frr-k8s-controller "$FRRK8S" 7572
  capture frr-k8s-frr "$FRRK8S" 7573
fi

step "3. monitors/services already present (does anything scrape MetalLB without us?)"
k -n "$NS" get servicemonitors,podmonitors 2>/dev/null || echo "  (no monitoring.coreos.com CRDs on this stack — none)"
k -n "$NS" get svc

step "4. key label shapes (paste into fixtures/README.md)"
for f in "$FIX"/*-metrics.txt; do
  echo "--- $(basename "$f")"
  grep -hE '^(metallb_|frrk8s_)[a-z0-9_]*(session_up|addresses_in_use_total|config_loaded_bool|announced)' "$f" | head -12
done

step "5. versions (provenance)"
echo "metallb chart: ${METALLB_CHART_VERSION}"
k -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u

green "fixtures written to ${FIX}. Next: ../generate-allowlist.sh, update fixtures/README.md, revise docs/roadmap.md"
