#!/usr/bin/env bash
#
# scenarios.sh — drive EVERY alert of this chart to firing and back on the real kind stack
# (run up.sh first). Each scenario breaks something real — Velero's bucket, a schedule that
# never succeeds, deleted backups + a Velero restart, the scrape path — and asserts the alert
# is FIRING in Prometheus AND DELIVERED to Alertmanager, then that it RESOLVES by itself.
#
# Timings come from values-e2e.yaml (budget 3m, for 1m, failure window 5m) — the rule
# expressions are the production ones. Takes ~40 minutes.
# Writes tests/reports/e2e-kind-<date>.md and dashboard screenshots to docs/images/.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
FAILED=0
ONLY=("$@")          # e.g. `scenarios.sh 6b 6c` re-runs just those; no args = everything
want() { [ ${#ONLY[@]} -eq 0 ] && return 0; local x; for x in "${ONLY[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
# One run at a time: two concurrent runs break each other's scenarios on the shared cluster.
LOCK="${TMPDIR:-/tmp}/${CLUSTER}.scenarios.lock"
mkdir "$LOCK" 2>/dev/null || { red "another scenarios.sh run holds $LOCK"; exit 1; }
trap 'stop_port_forwards; rmdir "$LOCK"' EXIT
port_forwards || exit 1
SCHED=default-object-schedule
# Per-run suffix: a schedule name reused across runs could inherit Completed backups that
# Velero's backup-sync re-imports from the bucket, and would then legitimately NOT be
# "never succeeded" (seen on a re-run: Stale fired instead, correctly).
NEVER="never-succeeds-$(date +%H%M)"

schedule() {  # schedule <name> [budget-hours]: OADP-like daily schedule; runs are triggered by hand.
  # With a budget, the schedule carries its own RPO via the annotation the state exporter reads.
  local ann=""; [ -n "${2:-}" ] && ann="
  annotations: {oadp-observability.stakater.com/max-age-hours: \"$2\"}"
  k apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: $1
  namespace: ${NS}${ann}
spec:
  schedule: "0 1 * * *"
  template: {includedNamespaces: [demo], storageLocation: dpa-1, ttl: 48h0m0s}
EOF
}
run_backup() {  # run_backup <schedule> [--wait]
  velero backup create --from-schedule "$1" ${2:-} >/dev/null 2>&1 || true
}
last_phase() {
  k -n "$NS" get backups -l velero.io/schedule-name="$1" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null
}
bsl_bucket() { k -n "$NS" patch bsl dpa-1 --type merge -p "{\"spec\":{\"objectStorage\":{\"bucket\":\"$1\"}}}" >/dev/null; }
EXPORTER_SVC="oadp-observability-state-exporter"

if want 0; then
step "0. clean slate: no schedules, no backups (in the cluster AND the bucket)"
k -n "$NS" patch bsl dpa-1 --type merge -p '{"spec":{"objectStorage":{"bucket":"velero"}}}' >/dev/null
k -n "$NS" delete schedules --all >/dev/null
# `velero backup delete` removes the objects from the bucket too; deleting only the CRs
# lets backup-sync re-import them.
velero backup delete --all --confirm >/dev/null 2>&1 || true
for _ in $(seq 1 30); do [ -z "$(k -n "$NS" get backups -o name 2>/dev/null)" ] && break; sleep 5; done
echo "  backups left: $(k -n "$NS" get backups -o name 2>/dev/null | wc -l | tr -d ' ')"
# Let the previous run's alerts (e.g. the 5m failure window) clear before asserting quiet.
# target="schedules" is expected to fire here: no Schedule exists yet.
for _ in $(seq 1 60); do
  n=$(curl -sf "$PROM/api/v1/alerts" | python3 -c 'import json,sys;print(len([a for a in json.load(sys.stdin)["data"]["alerts"] if a["labels"].get("target")!="schedules"]))')
  [ "$n" = 0 ] && break; sleep 10
done
echo "  leftover alerts: ${n:-?}"
fi

if want 0; then
step "0. baseline: one daily schedule (annotated 3m budget), one Completed backup -> everything quiet"
k create namespace demo --dry-run=client -o yaml | k apply -f - >/dev/null
k -n demo create configmap app-config --from-literal=k=v --dry-run=client -o yaml | k apply -f - >/dev/null
schedule "$SCHED" 0.05   # its own budget: 3 minutes (the chart default in values-e2e is 6)
run_backup "$SCHED" --wait
echo "  latest ${SCHED} backup: $(last_phase "$SCHED")"
sleep 60   # scrape + rule evaluation
for a in OadpBackupStale OadpBackupNoSuccessfulBackup OadpBackupStorageLocationUnavailable OadpBackupFailed OadpRestoreFailed OadpDataMoverFailed OadpNodeAgentUnavailable OadpMetricsAbsent OadpTargetDown; do
  expect_inactive "0 baseline" "$a" '{}'
done
fi

if want 1; then
step "1. stale: the last success ages past the schedule's OWN budget (3m, from its annotation)"
expect_value  "1 stale" "oadp:schedule_budget_seconds{schedule=\"$SCHED\"}" 180
# 300s deadline discriminates: had the annotation been ignored, the 6m default + 1m for = 7m.
expect_firing   "1 stale" OadpBackupStale "{\"schedule\":\"$SCHED\"}" 300
expect_inactive "1 stale" OadpBackupNoSuccessfulBackup "{\"schedule\":\"$SCHED\"}"
fi

if want 2; then
step "2. bucket unreachable: BSL points at a missing bucket; the next run fails validation"
bsl_bucket no-such-bucket
expect_firing "2 bucket" OadpBackupStorageLocationUnavailable '{"name":"dpa-1"}' 300
run_backup "$SCHED"
sleep 15; echo "  latest ${SCHED} backup: $(last_phase "$SCHED")"
expect_firing "2 bucket" OadpBackupFailed "{\"schedule\":\"$SCHED\",\"phase\":\"FailedValidation\"}" 180
fi

if want 3; then
step "3. never succeeded: a new UNANNOTATED schedule (default 6m budget) whose every run fails validation"
schedule "$NEVER"
run_backup "$NEVER"
expect_value  "3 never" "oadp:schedule_budget_seconds{schedule=\"$NEVER\"}" 360
expect_firing   "3 never" OadpBackupNoSuccessfulBackup "{\"schedule\":\"$NEVER\"}" 600
expect_inactive "3 never" OadpBackupStale "{\"schedule\":\"$NEVER\"}"
"${E2E}/screenshots.sh" failing || FAILED=1
fi

if want 4; then
step "4. expired + restarted: Completed backups gone, Velero restarts -> success series ABSENT"
k -n "$NS" delete backups -l velero.io/schedule-name="$SCHED" --wait=false >/dev/null
k -n "$NS" rollout restart deploy/velero >/dev/null && k -n "$NS" rollout status deploy/velero --timeout=180s >/dev/null
expect_firing   "4 expired" OadpBackupNoSuccessfulBackup "{\"schedule\":\"$SCHED\"}" 300
expect_resolved "4 expired" OadpBackupStale "{\"schedule\":\"$SCHED\"}" 300
fi

if want 5; then
step "5. recovery: fix the bucket, run both schedules -> every alert resolves by itself"
bsl_bucket velero
expect_resolved "5 recovery" OadpBackupStorageLocationUnavailable '{"name":"dpa-1"}' 300
run_backup "$SCHED" --wait; run_backup "$NEVER" --wait
echo "  latest: ${SCHED}=$(last_phase "$SCHED") ${NEVER}=$(last_phase "$NEVER")"
expect_resolved "5 recovery" OadpBackupNoSuccessfulBackup "{\"schedule\":\"$SCHED\"}" 240
expect_resolved "5 recovery" OadpBackupNoSuccessfulBackup "{\"schedule\":\"$NEVER\"}" 240
expect_resolved "5 recovery" OadpBackupFailed "{\"schedule\":\"$SCHED\"}" 480
fi

if want 6a; then
step "6a. watchdog: Velero scrape target exists but fails (wrong port)"
k -n "$NS" patch svc openshift-adp-velero-metrics-svc --type json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8086}]' >/dev/null
expect_firing "6a target down" OadpTargetDown '{"target":"velero"}' 240
# Blind on Velero's series: the outcome alert pages instead of going silent (by design).
expect_firing "6a target down" OadpBackupNoSuccessfulBackup "{\"schedule\":\"$SCHED\"}" 240
k apply -f "${E2E}/stack/oadp-metrics-service.yaml" >/dev/null
expect_resolved "6a target down" OadpTargetDown '{"target":"velero"}' 240
fi

if want 6b; then
step "6b. watchdog: Velero scrape target vanishes (Service deleted)"
k -n "$NS" delete svc openshift-adp-velero-metrics-svc >/dev/null
# absent() worst case: a vanished series can stay visible for the 5m lookback (no staleness
# marker written) + for: 1m. Run 7 fired 2s after a 240s timeout for exactly this reason.
expect_firing "6b absent" OadpMetricsAbsent '{"target":"velero"}' 480
k apply -f "${E2E}/stack/oadp-metrics-service.yaml" >/dev/null
expect_resolved "6b absent" OadpMetricsAbsent '{"target":"velero"}' 240
fi

if want 6c; then
step "6c. watchdog: state exporter gone (scaled to 0) -> BSL and Schedule series absent"
k -n "$NS" scale deploy/${EXPORTER_SVC} --replicas=0 >/dev/null
expect_firing "6c exporter absent" OadpMetricsAbsent '{"target":"backupstoragelocations"}' 480
expect_firing "6c exporter absent" OadpMetricsAbsent '{"target":"schedules"}' 60
k -n "$NS" scale deploy/${EXPORTER_SVC} --replicas=1 >/dev/null
expect_resolved "6c exporter absent" OadpMetricsAbsent '{"target":"backupstoragelocations"}' 240
expect_resolved "6c exporter absent" OadpMetricsAbsent '{"target":"schedules"}' 60
fi

if want 6d; then
step "6d. watchdog: state exporter target exists but its scrape fails (404)"
# Wait until the exporter (recreated in 6c) is stably scraped before breaking it.
for _ in $(seq 1 30); do
  v=$(curl -sf "$PROM/api/v1/query" --data-urlencode "query=min_over_time(up{job=\"${EXPORTER_SVC}\"}[1m])" | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")')
  [ "$v" = 1 ] && break; sleep 10
done
# Break the scrape, not the discovery: the target stays, kube-state-metrics answers 404, up=0.
k -n "$NS" patch servicemonitor ${EXPORTER_SVC} --type json \
  -p '[{"op":"replace","path":"/spec/endpoints/0/path","value":"/broken"}]' >/dev/null
expect_firing "6d target down" OadpTargetDown '{"target":"state-exporter"}' 300
k -n "$NS" patch servicemonitor ${EXPORTER_SVC} --type json \
  -p '[{"op":"replace","path":"/spec/endpoints/0/path","value":"/metrics"}]' >/dev/null
expect_resolved "6d target down" OadpTargetDown '{"target":"state-exporter"}' 300
fi

if want 8; then
step "8. restore failure: a restore from a backup that does not exist -> FailedValidation"
# Created as a Restore OBJECT, as GitOps/automation would: the velero CLI refuses a missing
# backup client-side, so it never reaches the server. A named-backup restore carries
# schedule="" (the restore's spec.scheduleName) -> no schedule label on the alert.
k apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata: {name: e2e-bad-restore-$(date +%H%M%S), namespace: ${NS}}
spec: {backupName: no-such-backup}
EOF
expect_firing   "8 restore" OadpRestoreFailed '{"phase":"FailedValidation"}' 240
expect_resolved "8 restore" OadpRestoreFailed '{"phase":"FailedValidation"}' 600
fi

if want 9; then
step "9. volume data: a file-system backup of a pod volume through the node-agent (Kopia)"
k create namespace demo-vol --dry-run=client -o yaml | k apply -f - >/dev/null
# emptyDir, not a PVC: kind's local-path PVs are hostPath volumes, which Velero's file-system
# backup skips by design (seen: backup Completed, zero PodVolumeBackups). emptyDir is supported.
k -n demo-vol apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: writer}
spec:
  containers:
    - {name: writer, image: "busybox:1.37", command: ["sh","-c","echo hello > /data/f; sleep 36000"], volumeMounts: [{name: data, mountPath: /data}]}
  volumes: [{name: data, emptyDir: {}}]
EOF
k -n demo-vol wait --for=condition=Ready pod/writer --timeout=180s >/dev/null
velero backup create "fs-$(date +%H%M%S)" --include-namespaces demo-vol --default-volumes-to-fs-backup --wait >/dev/null 2>&1 || true
echo "  PodVolumeBackups: $(k -n "$NS" get podvolumebackups.velero.io -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}')"
# Proof the PodMonitor scrapes the node-agent and its counters move with real work:
expect_positive "9 volume" 'sum(podVolume_pod_volume_backup_dequeue_count)' 180
expect_inactive "9 volume" OadpDataMoverFailed '{}'

step "9b. node-agent unavailable: its image can't be pulled"
k -n "$NS" set image ds/node-agent node-agent=velero/velero:no-such-tag >/dev/null
expect_firing   "9b node-agent" OadpNodeAgentUnavailable '{"daemonset":"node-agent"}' 300
k -n "$NS" rollout undo ds/node-agent >/dev/null && k -n "$NS" rollout status ds/node-agent --timeout=180s >/dev/null
expect_resolved "9b node-agent" OadpNodeAgentUnavailable '{"daemonset":"node-agent"}' 300
k delete namespace demo-vol --wait=false >/dev/null
fi

if want 7; then
step "7. healthy again: fresh backups -> nothing firing"
run_backup "$SCHED" --wait; run_backup "$NEVER" --wait
for a in OadpBackupStale OadpBackupNoSuccessfulBackup OadpBackupStorageLocationUnavailable OadpBackupFailed OadpRestoreFailed OadpDataMoverFailed OadpNodeAgentUnavailable OadpMetricsAbsent OadpTargetDown; do
  expect_resolved "7 healthy" "$a" '{}' 300
done
"${E2E}/screenshots.sh" healthy || FAILED=1
fi

step "report"
SUFFIX=""; [ ${#ONLY[@]} -gt 0 ] && SUFFIX="-only-$(IFS=-; echo "${ONLY[*]}")"
REPORT="${CHART}/tests/reports/e2e-kind-$(date -u +%F)${SUFFIX}.md"
{
  echo "# e2e on kind — $(date -u +%F)"
  echo
  echo "Every alert of this chart driven to **firing** (in Prometheus, and delivered to"
  echo "Alertmanager) and back to **resolved** on a real stack: kind, kube-prometheus-stack 91.8.2,"
  echo "grafana-operator v5.25.0, **Velero 1.16.2** (what OADP 1.5 ships) with a SeaweedFS S3 bucket,"
  echo "the OADP-shaped metrics Service, and this chart with \`tests/e2e/values-e2e.yaml\`."
  echo
  echo "> **Timings are shortened** for the run (default budget 6m instead of 25h with the baseline schedule annotated 3m, \`for\` 1m instead of 15m,"
  echo "> failure window 5m instead of 12h). The rule expressions are the production ones."
  [ "$STALLS" -gt 0 ] && echo "> **Environment:** Prometheus stalled ${STALLS} time(s) during this run (missed rule iterations — the Docker VM pausing); affected waits were extended once and are marked in the table." && echo ">"
  echo "> Not exercised here: OpenShift user-workload monitoring's namespace enforcement, and the"
  echo "> \`Failed\` / \`PartiallyFailed\` phases (covered by \`tests/unit/rules.test.yaml\`)."
  echo
  echo "| Scenario | Alert | Expected | Result |"
  echo "| --- | --- | --- | --- |"
  printf '%s\n' "${REPORT_ROWS[@]}"
  echo
  [ "$FAILED" = 0 ] && echo "**Result: PASS**" || echo "**Result: FAIL**"
} > "$REPORT"
echo "wrote $REPORT"
[ "$FAILED" = 0 ] && green "E2E PASSED" || { red "E2E FAILED"; exit 1; }
