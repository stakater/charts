#!/usr/bin/env bash
# scenarios.sh — drives the chart's alerts to FIRE and RESOLVE on the live e2e
# cluster (see up.sh / README.md). Prints PASS/FAIL lines; exit code reflects
# them. The chart must be installed with values-e2e.yaml (shrunk windows).
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

RESULTS=()
run() { # tag command... (command prints exactly one PASS/FAIL line)
  shift 0; local tag=$1; shift
  local out
  out=$("$@") || true
  RESULTS+=("[$tag] $out"); echo "[$tag] $out"
}

DAILY=', costjob="daily-scraping-job"'
FINOPS_NS=finops-operator-system

prom_up
echo "== Scenario 1: finops cost pipeline lifecycle (stories 7.1/7.2)"
echo "-- 1a. a real Success resolves Failing and NeverSucceeded for the job"
run s1a1 wait_resolved MTOCostJobFailing 420 "$DAILY"
run s1a2 wait_resolved MTOCostJobNeverSucceeded 420 "$DAILY"

echo "-- 1b. OpenCost outage: loaders fail, the last success ages -> Failing AND Stale fire"
# (CronJob suspend is NOT a usable forcing mechanism: the operator's
# CreateOrUpdate reverts spec.suspend on its next reconcile - itself a
# finding. An OpenCost outage is also the truer eu-1 shape.)
scale "$FINOPS_NS" opencost 0
run s1b1 wait_firing MTOCostJobFailing 600 "$DAILY"
run s1b2 wait_firing MTOCostDataStale 600 "$DAILY"

echo "-- 1c. OpenCost back: the next Success resolves both"
scale "$FINOPS_NS" opencost 1
run s1c1 wait_resolved MTOCostJobFailing 600 "$DAILY"
run s1c2 wait_resolved MTOCostDataStale 600 "$DAILY"

echo "== Scenario 2: operator Down fire+resolve per operator (story 1.1)"
down_cycle() { # alert ns deploy
  scale "$2" "$3" 0
  run "down/$3" wait_firing "$1" 420
  scale "$2" "$3" 1
  run "up/$3" wait_resolved "$1" 600
}
down_cycle MTOFinopsOperatorDown      "$FINOPS_NS"                finops-operator-controller-manager
down_cycle MTOHibernationOperatorDown hibernation-operator-system hibernation-operator-controller-manager
down_cycle MTOTemplateOperatorDown    template-operator-v2-system template-operator-v2-controller-manager
down_cycle MTOTenantOperatorDown      multi-tenant-operator       tenant-operator-tenant-controller

echo "== Scenario 3: finops metrics watchdog (MTOFinopsMetricsAbsent)"
scale "$FINOPS_NS" finops-operator-controller-manager 0
run s3a wait_firing MTOFinopsMetricsAbsent 420
scale "$FINOPS_NS" finops-operator-controller-manager 1
run s3b wait_resolved MTOFinopsMetricsAbsent 600

echo "== Scenario 4: reconcile errors, finops representative (story 3.2)"
# Killing the finops database makes Offering/Subscription syncs error on
# every requeue; touching the Offering keeps reconciles flowing.
scale "$FINOPS_NS" capture-postgres 0
for i in 1 2 3 4 5 6; do
  kubectl -n "$FINOPS_NS" annotate offering foo e2e/touch="$i-$(date +%s)" --overwrite >/dev/null 2>&1
  sleep 20
done
run s4a wait_firing MTOFinopsOperatorReconcileErrors 420
scale "$FINOPS_NS" capture-postgres 1
run s4b wait_resolved MTOFinopsOperatorReconcileErrors 900

echo "== Summary"
fails=$(printf '%s\n' "${RESULTS[@]}" | grep -c ' FAIL ' || true)
printf '%s\n' "${RESULTS[@]}"
echo "failures: ${fails}"
exit "$fails"
