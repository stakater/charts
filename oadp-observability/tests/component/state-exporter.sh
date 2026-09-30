#!/usr/bin/env bash
#
# state-exporter.sh — component test for the chart's OADP state exporter (docs/state-exporter.md).
#
# The exporter's behaviour (metric names, StateSet shape, RFC3339 -> unix parsing, the RBAC
# it needs) comes from kube-state-metrics docs, not observation. This test observes it:
# a throwaway kind cluster gets the pinned Velero 1.16 CRDs, an Unavailable BSL (every-backup-fails
# shape) and a Schedule; the chart's own exporter manifests (its ServiceAccount + ClusterRole,
# so RBAC gaps fail here) are deployed; /metrics is scraped and asserted.
#
# The scrape is written to tests/fixtures/state-exporter-metrics.txt — a real capture of
# our real exporter (provenance: kind + KSM v2.20.0, not OpenShift), which the metric gate
# then counts as CAPTURED.
#
# Usage: ./tests/component/state-exporter.sh [--keep]   (--keep leaves the cluster up)
# Needs: kind, kubectl, helm, curl, docker. Pulls kindest/node + the KSM image.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/../.." && pwd)"
C="${CHART}/tests/component"
CLUSTER="oadp-obs-ct"
CTX="kind-${CLUSTER}"
NS="openshift-adp"
FIXTURE="${CHART}/tests/fixtures/state-exporter-metrics.txt"
KEEP="${1:-}"
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
step()  { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }
# Isolated kubeconfig: `kind create cluster` would otherwise switch the caller's
# current-context in ~/.kube/config (it did, on the first run of this script).
export KUBECONFIG="$(mktemp -t oadp-obs-ct-kubeconfig)"
k() { kubectl --context "$CTX" "$@"; }

cleanup() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
  if [ "$KEEP" != "--keep" ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    rm -f "$KUBECONFIG"
  else
    echo "cluster kept; KUBECONFIG=$KUBECONFIG"
  fi
}
trap cleanup EXIT

step "1. kind cluster ${CLUSTER}"
if kind get clusters | grep -qx "$CLUSTER"; then kind export kubeconfig --name "$CLUSTER" >/dev/null
else kind create cluster --name "$CLUSTER" --wait 120s; fi
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null

step "2. Velero 1.16 CRDs + an Unavailable BSL and a Schedule"
k apply -f "${C}/crds/" >/dev/null
k wait --for=condition=Established crd/backupstoragelocations.velero.io crd/schedules.velero.io --timeout=60s >/dev/null
# These CRDs have no status subresource, so status is set with the object itself.
k apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata: {name: dpa-1, namespace: ${NS}}
spec:
  provider: aws
  objectStorage: {bucket: test-bucket}
status:
  phase: Unavailable
---
apiVersion: velero.io/v1
kind: Schedule
metadata: {name: default-object-schedule, namespace: ${NS}}
spec:
  schedule: "0 1 * * *"
  template: {includedNamespaces: ["*"]}
---
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: db-hourly
  namespace: ${NS}
  annotations:
    oadp-observability.stakater.com/max-age-hours: "2"   # the schedule's own RPO budget
spec:
  schedule: "0 * * * *"
  template: {includedNamespaces: ["db"]}
EOF
green "BSL dpa-1 (Unavailable) + Schedules default-object-schedule (unannotated), db-hourly (budget 2h) created"

step "3. deploy the chart's state exporter (no ServiceMonitor: no prometheus-operator here)"
# runAsUser: kind has no SCC to assign a UID and the KSM image user is non-numeric.
helm template oadp "$CHART" -n "$NS" --set stateExporter.enabled=true --set stateExporter.runAsUser=65534 \
  -s templates/state-exporter/configmap.yaml \
  -s templates/state-exporter/rbac.yaml \
  -s templates/state-exporter/deployment.yaml \
  -s templates/state-exporter/service.yaml | k apply -n "$NS" -f - >/dev/null
if ! k -n "$NS" rollout status deploy/oadp-oadp-observability-state-exporter --timeout=180s; then
  red "exporter did not become ready:"; k -n "$NS" get pods -o wide
  k -n "$NS" describe pods -l app.kubernetes.io/component=state-exporter | tail -25
  k -n "$NS" logs -l app.kubernetes.io/component=state-exporter --tail=40 || true
  exit 1
fi

step "4. scrape /metrics"
k -n "$NS" port-forward svc/oadp-oadp-observability-state-exporter 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
METRICS=""
for _ in $(seq 1 30); do
  METRICS="$(curl -sf localhost:18080/metrics || true)"
  echo "$METRICS" | grep -q '^kube_customresource_schedule_max_age_hours' && \
  echo "$METRICS" | grep -q '^kube_customresource_schedule_created' && \
  echo "$METRICS" | grep -q '^kube_customresource_backupstoragelocation_status_phase' && break
  sleep 2
done

step "5. assertions"
fail=0
check() {  # check <description> <extended-regex>
  if echo "$METRICS" | grep -Eq "$2"; then green "  ok: $1"; else red "  FAIL: $1  (no line matches /$2/)"; fail=1; fi
}
check "BSL dpa-1 phase=Unavailable is 1" \
  '^kube_customresource_backupstoragelocation_status_phase\{.*name="dpa-1".*phase="Unavailable".*\} 1$'
check "BSL dpa-1 phase=Available is 0 (what OadpBackupStorageLocationUnavailable keys on)" \
  '^kube_customresource_backupstoragelocation_status_phase\{.*name="dpa-1".*phase="Available".*\} 0$'
check "Schedule created carries schedule= label" \
  '^kube_customresource_schedule_created\{.*schedule="default-object-schedule".*\} '
# The budget annotation is a STRING ("2"); KSM must turn it into a numeric gauge.
check "annotated schedule exports its budget: schedule_max_age_hours{schedule=db-hourly} 2" \
  '^kube_customresource_schedule_max_age_hours\{.*schedule="db-hourly".*\} 2$'
if echo "$METRICS" | grep -Eq '^kube_customresource_schedule_max_age_hours\{.*schedule="default-object-schedule"'; then
  red "  FAIL: unannotated schedule must NOT export a budget series (the recording rule supplies the default)"; fail=1
else
  green "  ok: unannotated schedule exports no budget series"
fi
# RFC3339 must be parsed to unix seconds (within an hour of now), not 0 / an error.
CREATED="$(echo "$METRICS" | grep -E '^kube_customresource_schedule_created\{' | awk '{print $NF}' | head -1)"
NOW="$(date +%s)"
if python3 -c "import sys; v=float('${CREATED:-0}'); sys.exit(0 if abs(v-${NOW})<3600 else 1)"; then
  green "  ok: schedule_created is a unix timestamp (${CREATED})"
else
  red "  FAIL: schedule_created=${CREATED:-<none>} is not ~now (${NOW}) — RFC3339 not parsed?"; fail=1
fi
# Our series must not carry their own `namespace` label: UWM enforces the target's and a
# second one would surface as exported_namespace, breaking every `on (namespace, ...)` join.
if echo "$METRICS" | grep -E '^kube_customresource_' | grep -q 'namespace='; then
  red "  FAIL: exporter series carry a namespace label (would become exported_namespace in UWM)"; fail=1
else
  green "  ok: no namespace label on exporter series"
fi

step "6. write fixture"
mkdir -p "$(dirname "$FIXTURE")"
{
  echo "# state-exporter-metrics.txt — REAL scrape of this chart's state exporter"
  echo "# (kube-state-metrics $(helm show values "$CHART" | awk '/^    tag:/{print $2; exit}'), config templates/state-exporter/configmap.yaml)"
  echo "# on kind with Velero 1.16 CRDs; captured by tests/component/state-exporter.sh."
  echo "# Provenance is kind, not OpenShift: it proves OUR exporter's output shape."
  echo "$METRICS" | grep -E '^(# (HELP|TYPE) )?kube_customresource_' \
    | sed -E 's/^(kube_customresource_schedule_created\{[^}]*\}) .*/\1 1.7e+09/'
} > "$FIXTURE"
green "wrote $FIXTURE"

[ "$fail" = 0 ] && green "COMPONENT TEST PASSED" || { red "COMPONENT TEST FAILED"; echo "$METRICS" | grep -E 'kube_customresource_' ; exit 1; }
