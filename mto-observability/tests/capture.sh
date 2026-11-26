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
LOCAL_PORT=18443

PFS=()
cleanup() {
  for pf in ${PFS[@]+"${PFS[@]}"}; do kill "$pf" 2>/dev/null || true; done
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
  pod=$($K -n "$ns" get pod -l "$sel" -o name 2>/dev/null | head -1)
  if [ -z "$pod" ]; then
    echo "SKIP  ${name}: no pod matches -l ${sel} in ${ns} (not installed, or the selector needs revising — record it)"
    skipped=$((skipped+1)); continue
  fi
  $K -n "$ns" port-forward "$pod" ${LOCAL_PORT}:${port} >/dev/null 2>&1 &
  PFS+=($!); sleep 2
  out="${T}/fixtures/${name}-metrics.txt"
  if curl -sk --max-time 15 -H "Authorization: Bearer ${TOKEN}" \
       "https://127.0.0.1:${LOCAL_PORT}/metrics" > "$out" && [ -s "$out" ] \
       && head -1 "$out" | grep -qE '^#|^[a-zA-Z_]'; then
    echo "OK    ${name}: $(grep -c '^[a-zA-Z_]' "$out") series lines -> fixtures/${name}-metrics.txt"
    ok=$((ok+1))
  else
    echo "FAIL  ${name}: scrape failed or empty (port ${port} on ${pod#pod/}) — fixture removed"
    rm -f "$out"; failed=$((failed+1))
  fi
  kill "${PFS[${#PFS[@]}-1]}" 2>/dev/null || true
done

echo
echo "captured ${ok}, skipped ${skipped}, failed ${failed}"
echo "next: provenance in fixtures/README.md, ./tests/generate-allowlist.sh, re-tag the roadmap, ./tests/validate.sh"
[ "$failed" -eq 0 ]
