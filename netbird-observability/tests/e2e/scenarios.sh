#!/usr/bin/env bash
#
# scenarios.sh — drive the chart's alerts to FIRING and back on the kind stack (up.sh first).
# Two real NetBird instances run in mesh-a and mesh-b; every scenario that breaks one
# instance also asserts the OTHER stays quiet — the fleet property this chart exists for.
#
# Live-fired here: NetBirdTargetDown (x3 components), NetBirdMetricsAbsent, plus scrape and
# API-traffic reality checks. NOT live-fired (needs enrolled peers / an IdP, which the rig
# has none of): sync/store latency, requests-blocked, peers-disconnected, signal
# registration/forward failures — their LOGIC is covered by promtool unit tests
# (tests/unit/rules.test.yaml), and their metrics ride the documented allowlist until a
# fleet capture promotes them. The report says so explicitly.
#
# ONLY="0 2" ./scenarios.sh runs a subset.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
trap stop_port_forwards EXIT
port_forwards
FAILED=0
DEFAULT_ONLY="0 1 2 3 4 5 6"
ONLY="${ONLY:-$DEFAULT_ONLY}"
want() { [[ " $ONLY " == *" $1 "* ]]; }

ALL_ALERTS=(NetBirdTargetDown NetBirdMetricsAbsent NetBirdManagementApiErrorRateHigh
  NetBirdManagementApiLatencyHigh NetBirdManagementSyncLatencyHigh
  NetBirdManagementRequestsBlocked NetBirdManagementStoreSlow NetBirdPeersDisconnected
  NetBirdSignalRegistrationFailures NetBirdSignalForwardFailures
  NetBirdPodRestarting NetBirdPodOOM NetBirdPodCPUThrottled)

# Wait for the first scrape of all 6 targets before judging anything: right after up.sh
# the ServiceMonitors exist but Prometheus has not discovered/scraped them yet, and a
# baseline read in that window reports "none" about a perfectly healthy stack.
step "waiting for all 6 netbird targets to be scraped"
for _ in $(seq 1 60); do
  n=$(curl -sf "$PROM/api/v1/query" --data-urlencode 'query=sum(up{job=~"netbird-(management|signal|relay)-metrics"})' \
    | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else 0)' 2>/dev/null || echo 0)
  [ "${n%.*}" = 6 ] && { green "  $(ts) all 6 targets up"; break; }
  sleep 5
done

# ── 0. baseline: everything scraped, everything quiet ─────────────────────────────────────
if want 0; then
  step "scenario 0 — baseline: 6 targets up (3 components x 2 instances), all alerts quiet"
  expect_value "0 baseline" 'sum(up{job=~"netbird-(management|signal|relay)-metrics"})' 6
  for a in "${ALL_ALERTS[@]}"; do expect_inactive "0 baseline" "$a" '{}'; done
fi

# ── 1. management API traffic is really measured (and 4xx does NOT page) ──────────────────
if want 1; then
  step "scenario 1 — drive HTTP API traffic in ${NS_A}; counters move, 4xx-only stays quiet"
  k -n "$NS_A" delete pod e2e-curl --ignore-not-found >/dev/null 2>&1
  k -n "$NS_A" run e2e-curl --image=curlimages/curl:8.10.1 --restart=Never -- \
    sh -c 'for i in $(seq 1 120); do curl -s -o /dev/null http://netbird-management:8080/api/users; curl -s -o /dev/null http://netbird-management:8080/api/peers; sleep 1; done' >/dev/null
  # exported_endpoint, not endpoint: the scrape's own endpoint target label renames
  # NetBird's HTTP label (the on-cluster reality the api-error-rate denominator pins)
  expect_positive "1 api-traffic" "sum(rate(management_http_request_counter_total{namespace=\"${NS_A}\", exported_endpoint=\"\"}[5m]))" 240
  expect_positive "1 api-traffic" "sum(rate(management_http_request_counter_total{namespace=\"${NS_A}\", exported_endpoint=\"/api/users\"}[5m]))" 120
  expect_positive "1 api-traffic" "sum(rate(management_http_response_counter_code_total{namespace=\"${NS_A}\", code=\"401\"}[5m]))" 120
  # unauthenticated 401s are CLIENT errors: the 5xx alert must not move
  expect_inactive "1 api-traffic" NetBirdManagementApiErrorRateHigh "{\"namespace\": \"${NS_A}\"}"
  k -n "$NS_A" delete pod e2e-curl --ignore-not-found >/dev/null 2>&1 &
fi

# ── 2. NetBirdTargetDown: scrape fails (pod up, port dead) per component; other mesh quiet ─
if want 2; then
  step "scenario 2a — management scrape broken in ${NS_A}: TargetDown fires there only"
  break_scrape "$NS_A" netbird-management-metrics
  expect_firing   "2a mgmt-down"  NetBirdTargetDown "{\"namespace\": \"${NS_A}\", \"target\": \"management\"}"
  expect_inactive "2a mgmt-down"  NetBirdTargetDown "{\"namespace\": \"${NS_B}\"}"
  restore_scrape "$NS_A" netbird-management-metrics
  expect_resolved "2a mgmt-down"  NetBirdTargetDown "{\"namespace\": \"${NS_A}\", \"target\": \"management\"}"

  step "scenario 2b — signal scrape broken in ${NS_B}: TargetDown fires there only"
  break_scrape "$NS_B" netbird-signal-metrics
  expect_firing   "2b signal-down" NetBirdTargetDown "{\"namespace\": \"${NS_B}\", \"target\": \"signal\"}"
  expect_inactive "2b signal-down" NetBirdTargetDown "{\"namespace\": \"${NS_A}\"}"
  restore_scrape "$NS_B" netbird-signal-metrics
  expect_resolved "2b signal-down" NetBirdTargetDown "{\"namespace\": \"${NS_B}\", \"target\": \"signal\"}"

  step "scenario 2c — relay scrape broken in ${NS_A}: TargetDown fires there only"
  break_scrape "$NS_A" netbird-relay-metrics
  expect_firing   "2c relay-down" NetBirdTargetDown "{\"namespace\": \"${NS_A}\", \"target\": \"relay\"}"
  expect_inactive "2c relay-down" NetBirdTargetDown "{\"namespace\": \"${NS_B}\"}"
  restore_scrape "$NS_A" netbird-relay-metrics
  expect_resolved "2c relay-down" NetBirdTargetDown "{\"namespace\": \"${NS_A}\", \"target\": \"relay\"}"
fi

# ── 3. NetBirdMetricsAbsent: the target VANISHES (scaled to 0 -> no endpoints -> no series) ─
if want 3; then
  step "scenario 3 — signal scaled to 0 in ${NS_B}: the blindness watchdog fires, TargetDown cannot"
  k -n "$NS_B" scale deploy/netbird-signal --replicas=0 >/dev/null
  expect_firing   "3 signal-absent" NetBirdMetricsAbsent "{\"namespace\": \"${NS_B}\", \"target\": \"signal\"}"
  # the up series is GONE, so TargetDown (up==0) must NOT be the alert that covers this
  expect_inactive "3 signal-absent" NetBirdTargetDown "{\"namespace\": \"${NS_B}\", \"target\": \"signal\"}"
  expect_inactive "3 signal-absent" NetBirdMetricsAbsent "{\"namespace\": \"${NS_A}\"}"
  k -n "$NS_B" scale deploy/netbird-signal --replicas=1 >/dev/null
  k -n "$NS_B" rollout status deploy/netbird-signal --timeout=180s >/dev/null
  expect_resolved "3 signal-absent" NetBirdMetricsAbsent "{\"namespace\": \"${NS_B}\", \"target\": \"signal\"}"
fi

# ── 4. Grafana: the fleet dashboard imported, and both instances report peer-gauge series ──
if want 4; then
  step "scenario 4 — dashboard imported into Grafana; connected-streams gauge exists per instance"
  if curl -sf "$GRAFANA/api/search?query=NetBird" | grep -q "NetBird Fleet Observability"; then
    green "  $(ts) dashboard 'NetBird Fleet Observability' is imported"
    record "4 grafana" "fleet dashboard" imported "✅ found via /api/search"
  else
    red "  $(ts) dashboard NOT found in Grafana"
    record "4 grafana" "fleet dashboard" imported "❌ not found"; FAILED=1
  fi
  expect_value "4 grafana" 'count(sum by (namespace) (management_grpc_connected_streams_ratio{job="netbird-management-metrics"}))' 2
fi

# ── 5. NetBirdPodRestarting: a REAL crashloop (relay refuses to start without its auth
# secret) fires the footprint alert in the broken mesh only, and resolves on repair ───────
if want 5; then
  step "scenario 5 — relay crashloops in ${NS_B} (auth secret emptied): PodRestarting fires there only"
  k -n "$NS_B" set env deploy/netbird-relay NB_AUTH_SECRET="" >/dev/null
  expect_firing   "5 relay-crashloop" NetBirdPodRestarting "{\"namespace\": \"${NS_B}\", \"container\": \"netbird-relay\"}" 600
  expect_inactive "5 relay-crashloop" NetBirdPodRestarting "{\"namespace\": \"${NS_A}\"}"
  k -n "$NS_B" set env deploy/netbird-relay NB_AUTH_SECRET="e2e-relay-secret" >/dev/null
  k -n "$NS_B" rollout status deploy/netbird-relay --timeout=180s >/dev/null
  # resolves once the 5m window slides past the last crash
  expect_resolved "5 relay-crashloop" NetBirdPodRestarting "{\"namespace\": \"${NS_B}\", \"container\": \"netbird-relay\"}" 720
fi

# ── 6. NetBirdPodOOM: a REAL OOM-kill (management squeezed to 32Mi) fires; raising the
# limit back rolls a fresh pod and the alert resolves ─────────────────────────────────────
if want 6; then
  step "scenario 6 — management OOM-killed in ${NS_A} (32Mi limit): PodOOM fires there only"
  k -n "$NS_A" patch deploy/netbird-management --type json -p '[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"limits":{"memory":"32Mi"},"requests":{"memory":"16Mi"}}}]' >/dev/null
  expect_firing   "6 mgmt-oom" NetBirdPodOOM "{\"namespace\": \"${NS_A}\", \"container\": \"netbird-management\"}" 600
  expect_inactive "6 mgmt-oom" NetBirdPodOOM "{\"namespace\": \"${NS_B}\"}"
  k -n "$NS_A" patch deploy/netbird-management --type json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources"}]' >/dev/null
  k -n "$NS_A" rollout status deploy/netbird-management --timeout=300s >/dev/null
  # the OOMKilled reason latches on the OLD pod's series; the rollout replaces the pod,
  # the stale series goes away, and the alert must resolve rather than fire forever
  expect_resolved "6 mgmt-oom" NetBirdPodOOM "{\"namespace\": \"${NS_A}\", \"container\": \"netbird-management\"}" 720
  expect_resolved "6 mgmt-oom" NetBirdTargetDown "{\"namespace\": \"${NS_A}\", \"target\": \"management\"}" 600
fi

# ── report ────────────────────────────────────────────────────────────────────────────────
step "report"
R="${CHART}/tests/reports/e2e-kind-$(date -u +%Y-%m-%d)$( [ "$ONLY" != "$DEFAULT_ONLY" ] && echo "-only-${ONLY// /-}" ).md"
{
  echo "# netbird-observability e2e on kind — $(date -u +%Y-%m-%dT%H:%MZ)"
  echo
  echo "Stack: kind + kube-prometheus-stack 91.8.2 + grafana-operator 5.25.0 + TWO real"
  echo "NetBird v0.75.0 instances (management/signal/relay) in \`mesh-a\` and \`mesh-b\`,"
  echo "this chart installed in both (values-e2e.yaml timings). Scenarios run: \`${ONLY}\`."
  echo
  echo "| scenario | alert / check | expected | result |"
  echo "|---|---|---|---|"
  for r in "${REPORT_ROWS[@]}"; do echo "$r"; done
  echo
  echo "Prometheus stalls observed (waits auto-extended): ${STALLS}"
  echo
  echo "## Not live-fired on this rig (honest gap)"
  echo
  echo "Enrolling real peers needs an IdP + setup keys, which the rig does not run. These"
  echo "alerts' LOGIC is verified by promtool unit tests (tests/unit/rules.test.yaml) on"
  echo "synthetic series; their metric names ride the documented allowlist until a live"
  echo "fleet capture promotes them (tests/metrics-allowlist.documented.txt):"
  echo
  echo "- NetBirdManagementSyncLatencyHigh, NetBirdManagementRequestsBlocked,"
  echo "  NetBirdManagementStoreSlow, NetBirdPeersDisconnected (baseline leg),"
  echo "  NetBirdSignalRegistrationFailures, NetBirdSignalForwardFailures"
  echo "- NetBirdPodCPUThrottled (needs sustained CPU load against a limit; promtool-covered)"
} > "$R"
green "report: $R"

if [ "${FAILED}" = 1 ]; then red "SOME SCENARIOS FAILED"; exit 1; fi
green "ALL SCENARIOS PASSED"
