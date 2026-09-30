# Shared helpers for the kind e2e scripts. Source it; don't run it.
# Isolated kubeconfig: never touches the caller's ~/.kube/config or current context.
CLUSTER="oadp-obs-e2e"
export KUBECONFIG="${TMPDIR:-/tmp}/${CLUSTER}.kubeconfig"
CTX="kind-${CLUSTER}"
E2E="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${E2E}/../.." && pwd)"
NS="openshift-adp"
PROM="http://localhost:19090"
AM="http://localhost:19093"
GRAFANA="http://localhost:13000"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
step()  { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }
k() { kubectl --context "$CTX" "$@"; }
ts() { date -u +%H:%M:%SZ; }

# Port-forwards to Prometheus, Alertmanager and Grafana; killed on exit by the caller's trap.
PF_PIDS=()
port_forwards() {
  k -n monitoring port-forward svc/kps-prometheus 19090:9090 >/dev/null 2>&1 & PF_PIDS+=($!)
  k -n monitoring port-forward svc/kps-alertmanager 19093:9093 >/dev/null 2>&1 & PF_PIDS+=($!)
  k -n grafana port-forward svc/grafana-service 13000:3000 >/dev/null 2>&1 & PF_PIDS+=($!)
  for _ in $(seq 1 30); do curl -sf "$PROM/-/ready" >/dev/null && curl -sf "$AM/-/ready" >/dev/null && return 0; sleep 1; done
  red "port-forwards did not come up"; return 1
}
stop_port_forwards() { for p in "${PF_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }

# alert_state <alertname> <label-matcher-json> -> prints firing|pending|inactive (Prometheus view)
alert_state() {
  curl -sf "$PROM/api/v1/alerts" | python3 -c '
import json, sys
name, want = sys.argv[1], json.loads(sys.argv[2])
st = "inactive"
for a in json.load(sys.stdin)["data"]["alerts"]:
    l = a["labels"]
    if l.get("alertname") == name and all(l.get(k) == v for k, v in want.items()):
        st = "firing" if a["state"] == "firing" else ("pending" if st != "firing" else st)
print(st)' "$1" "${2:-{\}}"
}
# in_alertmanager <alertname> <label-matcher-json> -> exit 0 if Alertmanager holds it active
in_alertmanager() {
  curl -sf "$AM/api/v2/alerts?active=true" | python3 -c '
import json, sys
name, want = sys.argv[1], json.loads(sys.argv[2])
ok = any(a["labels"].get("alertname") == name and all(a["labels"].get(k) == v for k, v in want.items())
         for a in json.load(sys.stdin))
sys.exit(0 if ok else 1)' "$1" "${2:-{\}}"
}

REPORT_ROWS=()
STALLS=0

# missed_iterations <seconds>: rule-group iterations Prometheus MISSED in the window. >0 means
# Prometheus itself stalled (on a laptop: the Docker VM paused), so a timeout in that window
# says nothing about the rules. Seen twice: a whole-Prometheus pause of ~3 min, with scrapes
# of unrelated targets gapping at the same moment.
missed_iterations() {
  curl -sf "$PROM/api/v1/query" --data-urlencode "query=sum(increase(prometheus_rule_group_iterations_missed_total[${1}s]))" \
    | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(round(float(r[0]["value"][1])) if r else 0)'
}
record() { REPORT_ROWS+=("| $1 | $2 | $3 | $4 |"); }   # scenario | alert | expected | result

# expect_firing <scenario> <alert> <matcher-json> <timeout-s>: firing in Prometheus AND delivered to Alertmanager
expect_firing() {
  local sc="$1" a="$2" m="$3" t="${4:-420}" start=$SECONDS note="" miss
  while :; do
    if (( SECONDS - start >= t )); then
      miss=$(missed_iterations $((SECONDS - start)))
      if [ -z "$note" ] && [ "${miss:-0}" -gt 0 ]; then
        note=" (Prometheus stalled: ${miss} missed rule iterations; wait extended)"; STALLS=$((STALLS+1))
        red "  $(ts) Prometheus stalled (${miss} missed iterations) — extending wait for $a"; t=$((t*2))
      else break; fi
    fi
    if [ "$(alert_state "$a" "$m")" = firing ] && in_alertmanager "$a" "$m"; then
      green "  $(ts) FIRING  $a $m  (+$((SECONDS-start))s, in Alertmanager)"; record "$sc" "$a $m" firing "✅ firing after $((SECONDS-start))s, delivered to Alertmanager${note}"; return 0
    fi; sleep 10
  done
  red "  $(ts) TIMEOUT waiting for $a $m to fire (state: $(alert_state "$a" "$m"))"; record "$sc" "$a $m" firing "❌ not firing after ${t}s"; FAILED=1; return 1
}
# expect_resolved <scenario> <alert> <matcher-json> <timeout-s>
expect_resolved() {
  local sc="$1" a="$2" m="$3" t="${4:-420}" start=$SECONDS note="" miss
  while :; do
    if (( SECONDS - start >= t )); then
      miss=$(missed_iterations $((SECONDS - start)))
      if [ -z "$note" ] && [ "${miss:-0}" -gt 0 ]; then
        note=" (Prometheus stalled: ${miss} missed rule iterations; wait extended)"; STALLS=$((STALLS+1))
        red "  $(ts) Prometheus stalled (${miss} missed iterations) — extending wait for $a"; t=$((t*2))
      else break; fi
    fi
    if [ "$(alert_state "$a" "$m")" = inactive ]; then
      green "  $(ts) RESOLVED $a $m  (+$((SECONDS-start))s)"; record "$sc" "$a $m" resolved "✅ resolved after $((SECONDS-start))s${note}"; return 0
    fi; sleep 10
  done
  red "  $(ts) TIMEOUT waiting for $a $m to resolve"; record "$sc" "$a $m" resolved "❌ still $(alert_state "$a" "$m") after ${t}s"; FAILED=1; return 1
}
# expect_inactive <scenario> <alert> <matcher-json>: must NOT be pending/firing right now
# expect_inactive <scenario> <alert> <matcher-json>: must NOT be firing right now. A transient
# `pending` is noted, not failed: that is exactly what `for` absorbs (seen once on a freshly
# built stack — one evaluation of absent(up) before Velero's first scrape).
expect_inactive() {
  local s; s="$(alert_state "$2" "$3")"
  if [ "$s" = inactive ]; then green "  $(ts) quiet   $2 $3"; record "$1" "$2 $3" quiet "✅ quiet"
  elif [ "$s" = pending ]; then green "  $(ts) quiet   $2 $3 (transiently pending)"; record "$1" "$2 $3" quiet "✅ not firing (transiently pending; \`for\` absorbs it)"
  else red "  $(ts) UNEXPECTED $2 $3 is $s"; record "$1" "$2 $3" quiet "❌ $s"; FAILED=1; fi
}

# expect_value <scenario> <promql> <expected>: an instant query must return exactly this value
# Polls up to 90s: a series for a just-created object needs a scrape (15s) plus a rule
# evaluation (15s) before it exists (an instant check raced that once).
expect_value() {
  local sc="$1" q="$2" want="$3" got start=$SECONDS
  while :; do
    got=$(curl -sf "$PROM/api/v1/query" --data-urlencode "query=$q" | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "none")')
    python3 -c "import sys; sys.exit(0 if '$got'!='none' and abs(float('$got')-float('$want'))<1e-6 else 1)" && break
    (( SECONDS - start >= 90 )) && break; sleep 5
  done
  if python3 -c "import sys; sys.exit(0 if '$got'!='none' and abs(float('$got')-float('$want'))<1e-6 else 1)"; then
    green "  $(ts) value   $q = $got"; record "$sc" "\`$q\`" "= $want" "✅ $got"
  else red "  $(ts) WRONG VALUE $q = $got (want $want)"; record "$sc" "\`$q\`" "= $want" "❌ $got"; FAILED=1; fi
}

# velero CLI inside the server pod (the pattern the OADP docs use)
velero() { k -n "$NS" exec deploy/velero -c velero -- /velero "$@"; }
