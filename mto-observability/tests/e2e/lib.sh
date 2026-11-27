#!/usr/bin/env bash
# lib.sh — helpers for the mto-observability kind e2e. Sourced by scenarios.sh.
# Requires: kubectl context pointing at the e2e cluster, kube-prometheus-stack
# in the `monitoring` namespace.
set -euo pipefail

PROM_NS="${PROM_NS:-monitoring}"
PROM_SVC="${PROM_SVC:-kps-kube-prometheus-stack-prometheus}"
PROM_PORT_LOCAL="${PROM_PORT_LOCAL:-19090}"
PF_PID=""

prom_up() {
  kubectl -n "$PROM_NS" port-forward "svc/${PROM_SVC}" "${PROM_PORT_LOCAL}:9090" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
}
prom_down() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap prom_down EXIT

prom_query() { # expr -> first value or empty
  curl -s "http://127.0.0.1:${PROM_PORT_LOCAL}/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else '')"
}

alert_count() { # alertname [state] [extra_matchers] -> number of alert series
  local name=$1 state=${2:-firing} extra=${3:-}
  local v
  v=$(prom_query "count(ALERTS{alertname=\"${name}\", alertstate=\"${state}\"${extra}})")
  echo "${v:-0}" | cut -d. -f1
}

# wait_firing/wait_resolved poll until the alert reaches the state or the
# timeout passes; they echo PASS/FAIL lines consumed by the report.
wait_firing() { # alertname timeout_s [extra_matchers]
  local name=$1 timeout=$2 extra=${3:-} t=0
  while [ "$t" -lt "$timeout" ]; do
    if [ "$(alert_count "$name" firing "$extra")" -ge 1 ]; then
      echo "PASS  ${name} FIRING after ${t}s"; return 0
    fi
    sleep 10; t=$((t+10))
  done
  echo "FAIL ${name} did not fire within ${timeout}s"; return 1
}

wait_resolved() { # alertname timeout_s [extra_matchers]
  local name=$1 timeout=$2 extra=${3:-} t=0
  while [ "$t" -lt "$timeout" ]; do
    if [ "$(alert_count "$name" firing "$extra")" -eq 0 ] && [ "$(alert_count "$name" pending "$extra")" -eq 0 ]; then
      echo "PASS  ${name} RESOLVED after ${t}s"; return 0
    fi
    sleep 10; t=$((t+10))
  done
  echo "FAIL ${name} still firing/pending after ${timeout}s"; return 1
}

wait_costjob_status() { # costjob expected_status timeout_s
  local cj=$1 want=$2 timeout=$3 t=0
  while [ "$t" -lt "$timeout" ]; do
    local got
    got=$(kubectl -n finops-operator-system get costjob "$cj" -o jsonpath='{.status.lastExecutionStatus}' 2>/dev/null || true)
    if [ "$got" = "$want" ]; then echo "PASS  costjob/${cj} status=${want} after ${t}s"; return 0; fi
    sleep 10; t=$((t+10))
  done
  echo "FAIL costjob/${cj} never reached status=${want} in ${timeout}s"; return 1
}

scale() { # namespace deployment replicas
  kubectl -n "$1" scale "deploy/$2" --replicas="$3" >/dev/null
}

suspend_cronjobs() { # namespace true|false
  for cj in $(kubectl -n "$1" get cronjob -o name); do
    kubectl -n "$1" patch "$cj" -p "{\"spec\":{\"suspend\":$2}}" >/dev/null
  done
}
