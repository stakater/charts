#!/usr/bin/env bash
#
# capture.sh — capture live /metrics from every MTO suite operator into
# tests/fixtures/ (the metric-reality step of docs/roadmap.md; procedure notes in
# METRICS-CAPTURE.md).
#
# Read-only, except one TEMPORARY ServiceAccount + ClusterRoleBinding for the
# authenticated scrape — both removed on exit (trap), along with every
# port-forward it starts.
#
# Usage:
#   CONTEXT=<kube-context> [MTO_NS=multi-tenant-operator] \
#     [FINOPS_NS=$MTO_NS] [HIBERNATION_NS=$MTO_NS] [TEMPLATE_NS=$MTO_NS] \
#     ./tests/capture.sh
#
# Afterwards: fill tests/fixtures/README.md with provenance, run
# ./tests/generate-allowlist.sh, re-tag docs/roadmap.md against the capture, and
# re-run ./tests/validate.sh.
set -euo pipefail
T="$(cd "$(dirname "$0")" && pwd)"
: "${CONTEXT:?set CONTEXT to the kube context of the cluster running MTO}"
MTO_NS="${MTO_NS:-multi-tenant-operator}"
FINOPS_NS="${FINOPS_NS:-$MTO_NS}"
HIBERNATION_NS="${HIBERNATION_NS:-$MTO_NS}"
TEMPLATE_NS="${TEMPLATE_NS:-$MTO_NS}"
K="kubectl --context ${CONTEXT}"
SA=mto-obs-metrics-capture
CRB=mto-obs-metrics-capture
CURL_POD=mto-obs-metrics-capture-curl
# The scrape runs from a pod INSIDE the cluster: several operators' metrics
# servers enforce a TLS policy that macOS curl (LibreSSL) cannot negotiate,
# so a laptop-side port-forward scrape fails with a protocol-version alert.
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"

cleanup() {
  $K -n "$MTO_NS" delete pod "$CURL_POD" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  $K -n "$MTO_NS" delete serviceaccount "$SA" --ignore-not-found >/dev/null 2>&1 || true
  $K delete clusterrolebinding "$CRB" --ignore-not-found >/dev/null 2>&1 || true
  $K delete clusterrole "$CRB" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== temporary scrape identity (removed on exit)"
$K -n "$MTO_NS" create serviceaccount "$SA" >/dev/null
cat <<EOF | $K apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CRB}
rules:
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CRB}
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${MTO_NS}
EOF
TOKEN=$($K -n "$MTO_NS" create token "$SA" --duration=30m)

echo "== in-cluster curl pod (removed on exit)"
$K -n "$MTO_NS" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never \
  --command -- sleep 1800 >/dev/null
$K -n "$MTO_NS" wait --for=condition=ready pod "$CURL_POD" --timeout=120s >/dev/null

# component-name|namespace|pod-label-selector|container-port
TARGETS=(
  "tenant|$MTO_NS|control-plane=controller-manager-tenant|6443"
  "namespace|$MTO_NS|control-plane=controller-manager|6443"
  "quota-intconfig|$MTO_NS|control-plane=controller-manager-quota-intconfig|6443"
  "pilot|$MTO_NS|control-plane=controller-manager-pilot|6443"
  "webhook|$MTO_NS|control-plane=controller-manager-webhook|6443"
  "db-controller|$MTO_NS|control-plane=controller-manager-db-controller|6443"
  "extensions-argocd|$MTO_NS|control-plane=controller-manager-extensions-argocd|6443"
  "finops-operator|$FINOPS_NS|control-plane=controller-manager,app.kubernetes.io/name=finops-operator|8443"
  "hibernation-operator|$HIBERNATION_NS|control-plane=hibernation-controller-manager|6443"
  "hibernation-webhook|$HIBERNATION_NS|control-plane=hibernation-controller-manager-webhook|6443"
  "template-operator|$TEMPLATE_NS|control-plane=controller-manager,app.kubernetes.io/name=template-operator-v2|8443"
)

ok=0; skipped=0; failed=0
for t in "${TARGETS[@]}"; do
  IFS='|' read -r name ns sel port <<<"$t"
  pod=$($K -n "$ns" get pod -l "$sel" --field-selector=status.phase=Running -o name 2>/dev/null | head -1)
  if [ -z "$pod" ]; then
    echo "SKIP  ${name}: no running pod matches -l ${sel} in ${ns} (not installed, or the selector needs revising — record it)"
    skipped=$((skipped+1)); continue
  fi
  ip=$($K -n "$ns" get "$pod" -o jsonpath='{.status.podIP}')
  out="${T}/fixtures/${name}-metrics.txt"
  # Try HTTPS first, then plain HTTP: without a metrics cert dir
  # controller-runtime serves INSECURE http ("secure: false") — which scheme
  # answered is itself a scrape-surface fact, so it is printed.
  got=""
  for scheme in https http; do
    if $K -n "$MTO_NS" exec "$CURL_POD" -- curl -sk --max-time 15 \
         -H "Authorization: Bearer ${TOKEN}" \
         "${scheme}://${ip}:${port}/metrics" > "$out" 2>/dev/null && [ -s "$out" ] \
         && head -1 "$out" | grep -qE '^#|^[a-zA-Z_]'; then
      got="$scheme"; break
    fi
  done
  if [ -n "$got" ]; then
    echo "OK    ${name}: $(grep -c '^[a-zA-Z_]' "$out") series lines via ${got} -> fixtures/${name}-metrics.txt"
    ok=$((ok+1))
  else
    echo "FAIL  ${name}: scrape failed or empty (${ip}:${port}, https and http, from in-cluster curl) — fixture removed"
    rm -f "$out"; failed=$((failed+1))
  fi
done

echo
echo "captured ${ok}, skipped ${skipped}, failed ${failed}"
echo "next: provenance in fixtures/README.md, ./tests/generate-allowlist.sh, re-tag the roadmap, ./tests/validate.sh"
[ "$failed" -eq 0 ]
