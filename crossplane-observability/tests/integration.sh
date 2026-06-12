#!/usr/bin/env bash
#
# integration.sh — self-contained metric capture from a PINNED, ephemeral stack.
#
# Stands up kind + Crossplane + provider-kubernetes at the versions in tests/versions.env,
# creates a real in-cluster Object (a ConfigMap, no cloud credentials) so the provider
# emits the crossplane_managed_resource_* state metrics, scrapes the real /metrics off core
# and the provider into tests/fixtures/, and tears the cluster down. Everyday validation
# (tests/validate.sh) then runs OFFLINE against those committed fixtures.
#
# Re-run only when bumping versions.env. Requires: kind, kubectl, helm, curl.
#
#   ./tests/integration.sh            # create, capture, destroy
#   ./tests/integration.sh --keep     # leave the cluster up for inspection
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/versions.env"
FIX="${HERE}/fixtures"
CLUSTER="xp-obs-capture"
NS="crossplane-system"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
mkdir -p "$FIX"

cleanup() { [ "$KEEP" = "1" ] || kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo ">> creating kind cluster ($KIND_NODE_IMAGE)"
kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --wait 120s

echo ">> installing Crossplane $CROSSPLANE_VERSION"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null
helm repo update >/dev/null
helm install crossplane crossplane-stable/crossplane \
  --version "$CROSSPLANE_VERSION" \
  -n "$NS" --create-namespace \
  --set metrics.enabled=true --wait
kubectl -n "$NS" rollout status deploy/crossplane --timeout=180s

echo ">> installing provider-kubernetes ($PROVIDER_KUBERNETES_PACKAGE)"
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: ${PROVIDER_KUBERNETES_PACKAGE}
EOF
kubectl wait provider.pkg.crossplane.io/provider-kubernetes --for=condition=Healthy --timeout=240s

# provider-kubernetes uses a ServiceAccount to talk to the local API (InjectedIdentity).
# Grant it cluster-admin (test cluster only) so it can manage the sample Object.
echo ">> binding provider SA and creating a ProviderConfig (InjectedIdentity)"
SA="$(kubectl -n "$NS" get sa -o name | grep provider-kubernetes | head -1 | cut -d/ -f2)"
kubectl create clusterrolebinding pk-admin \
  --clusterrole=cluster-admin --serviceaccount="${NS}:${SA}" --dry-run=client -o yaml | kubectl apply -f -
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity
EOF

echo ">> creating a sample Object so managed-resource state metrics get series"
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha2
kind: Object
metadata:
  name: capture-sample
spec:
  forProvider:
    manifest:
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: capture-sample
        namespace: default
      data:
        hello: world
  providerConfigRef:
    name: default
EOF
kubectl wait object.kubernetes.crossplane.io/capture-sample --for=condition=Ready --timeout=120s || true
sleep 20
kubectl get managed || true

scrape() { # <port-forward target> <port> <dest>
  echo ">> scraping $1 -> $3"
  kubectl -n "$NS" port-forward "$1" "$2:$2" >/dev/null 2>&1 &
  local pf=$!; sleep 4
  curl -sf "localhost:$2/metrics" > "$3" || echo "WARN: scrape failed for $1" >&2
  kill "$pf" 2>/dev/null || true
}

scrape "deploy/crossplane" 8080 "${FIX}/core-metrics.txt"
PROV_POD="$(kubectl -n "$NS" get pods -l pkg.crossplane.io/provider=provider-kubernetes -o name | head -1)"
[ -n "$PROV_POD" ] && scrape "$PROV_POD" 8080 "${FIX}/provider-metrics.txt" || echo "WARN: no provider pod" >&2

echo ">> writing capture metadata"
cat > "${FIX}/CAPTURE.md" <<EOF
# Captured metric fixtures

Real Prometheus exposition scraped from a pinned, ephemeral stack by tests/integration.sh.
tests/validate.sh derives the captured allowlist from these and checks the chart offline.

| Component | Version |
| --- | --- |
| kind node | ${KIND_NODE_IMAGE} |
| Crossplane | ${CROSSPLANE_VERSION} |
| provider-kubernetes | ${PROVIDER_KUBERNETES_PACKAGE} |

Captured: $(date -u +%FT%TZ)

Note: function_run_* and circuit_breaker_* are core metrics that only register once a
composition function / realtime composition actually runs; this capture does not exercise
one, so those remain in metrics-allowlist.documented.txt (confirmed in the upstream docs).
EOF

echo ">> regenerating captured allowlist from fixtures"
# Include the committed inventory fixture (captured separately from a real cluster's
# ksm-crossplane exporter — kind has no exporter) so the captured allowlist stays complete.
"${HERE}/capture-metrics.sh" \
  --core "${FIX}/core-metrics.txt" \
  $( [ -f "${FIX}/provider-metrics.txt" ] && echo --provider "${FIX}/provider-metrics.txt" ) \
  $( [ -f "${FIX}/inventory-metrics.txt" ] && echo --inventory "${FIX}/inventory-metrics.txt" ) \
  -o "${HERE}/metrics-allowlist.captured.txt"

echo ">> done. Review & commit: tests/fixtures/* and tests/metrics-allowlist.captured.txt"
