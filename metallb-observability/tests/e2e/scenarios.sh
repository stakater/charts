#!/usr/bin/env bash
#
# scenarios.sh — drive every alert to FIRE and RESOLVE on the kind stack (run up.sh first).
# Each scenario breaks one real thing, waits for the alert in Prometheus AND Alertmanager,
# repairs it, and waits for resolution. Writes a dated report to tests/reports/.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
S="${E2E}/stack"
trap 'stop_port_forwards' EXIT
port_forwards

WORKER="${CLUSTER}-worker"
WORKER_IP="$(docker inspect "$WORKER" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
PFX="$(kind_subnet | cut -d. -f1-2)"; export PFX

step "S0 baseline — all targets scraped, sessions up, every alert quiet"
expect_positive s0-baseline 'count(up{job="metallb-controller"} == 1)'
expect_positive s0-baseline 'count(up{job="metallb-speaker"} == 1)'
expect_positive s0-baseline 'count(up{job="metallb-frr-k8s"} == 1)' 300
expect_positive s0-baseline 'count(frrk8s_bgp_session_up == 1)'
expect_positive s0-baseline 'count(frrk8s_bfd_session_up == 1)'
expect_positive s0-baseline 'metallb_allocator_addresses_in_use_total{pool="bgp-pool"}'
sleep 60   # one full for: window with everything healthy
for a in MetalLBAddressPoolExhausted MetalLBAddressPoolNearExhaustion MetalLBBGPSessionDown \
         MetalLBBGPSessionFlapping MetalLBBFDSessionDown MetalLBConfigNotLoaded MetalLBConfigStale \
         MetalLBK8sClientErrors MetalLBControllerDown MetalLBSpeakerDown MetalLBFRRK8sDown \
         MetalLBMetricsAbsent; do
  expect_inactive s0-baseline "$a" '{}'
done

step "S1 BGP peer outage — stop the FRR peer: session + BFD alerts fire, recover on restart"
docker stop "$FRR" >/dev/null
expect_firing s1-peer-outage MetalLBBGPSessionDown '{}' 300
expect_firing s1-peer-outage MetalLBBFDSessionDown '{}' 300
start_frr
expect_resolved s1-peer-outage MetalLBBGPSessionDown '{}' 420
expect_resolved s1-peer-outage MetalLBBFDSessionDown '{}' 420

step "S2 flapping peer — two more bounces inside the 5m window trip the flap alert"
docker stop "$FRR" >/dev/null; sleep 20; start_frr; sleep 30
docker stop "$FRR" >/dev/null; sleep 20; start_frr
expect_firing s2-flapping MetalLBBGPSessionFlapping '{}' 300
expect_resolved s2-flapping MetalLBBGPSessionFlapping '{}' 600
expect_resolved s2-flapping MetalLBBGPSessionDown '{}' 300

step "S3 pool exhaustion — a 2-IP pool filled by two Services"
envsubst '${PFX}' < "${S}/exhaust.yaml.tpl" | k apply -f -
expect_firing s3-exhaustion MetalLBAddressPoolExhausted '{"pool":"tiny-pool"}' 300
expect_firing s3-exhaustion MetalLBAddressPoolNearExhaustion '{"pool":"tiny-pool"}' 300
envsubst '${PFX}' < "${S}/exhaust.yaml.tpl" | k delete -f - >/dev/null
expect_resolved s3-exhaustion MetalLBAddressPoolExhausted '{"pool":"tiny-pool"}' 420
expect_resolved s3-exhaustion MetalLBAddressPoolNearExhaustion '{"pool":"tiny-pool"}' 420

step "S4 controller gone — scale to 0: the absent() clause fires; scale back resolves"
k -n "$NS" scale deploy metallb-controller --replicas=0
expect_firing s4-controller-down MetalLBControllerDown '{}' 300
k -n "$NS" scale deploy metallb-controller --replicas=1
expect_resolved s4-controller-down MetalLBControllerDown '{}' 420

step "S5 speaker scrape blocked — DROP ${WORKER_IP}:7472: per-target up==0 fires"
docker exec "$WORKER" iptables -I INPUT -p tcp -d "$WORKER_IP" --dport 7472 -j DROP
expect_firing s5-speaker-down MetalLBSpeakerDown "{\"node\":\"${WORKER}\"}" 300
docker exec "$WORKER" iptables -D INPUT -p tcp -d "$WORKER_IP" --dport 7472 -j DROP
expect_resolved s5-speaker-down MetalLBSpeakerDown "{\"node\":\"${WORKER}\"}" 420

step "S6 frr-k8s scrape blocked — DROP ${WORKER_IP}:9140-9141: BGP alerting blind on that node"
docker exec "$WORKER" iptables -I INPUT -p tcp -d "$WORKER_IP" --dport 9140 -j DROP
docker exec "$WORKER" iptables -I INPUT -p tcp -d "$WORKER_IP" --dport 9141 -j DROP
expect_firing s6-frrk8s-down MetalLBFRRK8sDown "{\"node\":\"${WORKER}\"}" 300
docker exec "$WORKER" iptables -D INPUT -p tcp -d "$WORKER_IP" --dport 9140 -j DROP
docker exec "$WORKER" iptables -D INPUT -p tcp -d "$WORKER_IP" --dport 9141 -j DROP
expect_resolved s6-frrk8s-down MetalLBFRRK8sDown "{\"node\":\"${WORKER}\"}" 420

step "S7 watchdog — speaker DaemonSet vanishes entirely: MetricsAbsent, not SpeakerDown"
k -n "$NS" patch ds metallb-speaker --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"e2e-blackout":"true"}}}}}' >/dev/null
expect_firing s7-watchdog MetalLBMetricsAbsent '{"target":"speaker"}' 420
expect_inactive s7-watchdog MetalLBSpeakerDown '{}'
# json replace, not a merge patch: merging nodeSelector maps would KEEP the
# blackout key and the pods would never come back (found the hard way).
k -n "$NS" patch ds metallb-speaker --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"kubernetes.io/os":"linux"}}]' >/dev/null
k -n "$NS" rollout status ds/metallb-speaker --timeout=180s || { red "speaker DS did not recover"; FAILED=1; }
expect_resolved s7-watchdog MetalLBMetricsAbsent '{"target":"speaker"}' 420

step "S8 config health — not-loaded/stale quiet; chaos-induced client errors (if any) resolve"
expect_inactive s8-config MetalLBConfigNotLoaded '{}'
expect_inactive s8-config MetalLBConfigStale '{}'
# The S4/S7 pod churn produces REAL k8s update errors (observed live: controller +1,
# speaker +3 while being replaced) — MetalLBK8sClientErrors firing then is the alert
# working, and it must clear once its 10m window slides past the chaos.
expect_resolved s8-config MetalLBK8sClientErrors '{}' 720

step "S9 dashboard delivered — grafana-operator imported the GrafanaDashboard CR"
if curl -sf "${GRAFANA}/api/search?query=MetalLB%20Observability" | grep -q '"uid":"metallb-observability"'; then
  green "  dashboard present in Grafana"; record s9-dashboard "GrafanaDashboard metallb-dashboard" imported "✅ found via Grafana API"
else
  red "  dashboard NOT found in Grafana"; record s9-dashboard "GrafanaDashboard metallb-dashboard" imported "❌ not found"; FAILED=1
fi

step "report"
REPORT="${E2E}/../reports/e2e-kind-$(date -u +%Y-%m-%d).md"
{
  echo "# metallb-observability alert e2e — kind lab, $(date -u +%Y-%m-%d)"
  echo
  echo "Stack: \`tests/e2e/\` (kind v1.33.4, MetalLB ${METALLB_CHART_VERSION} FRR-K8s mode, external FRR peer with BFD,"
  echo "kube-prometheus-stack 91.8.2, grafana-operator 5.25.0), chart installed with \`values-e2e.yaml\`"
  echo "(15s scrape, 1m \`for\` windows, flap window 5m). Prometheus stalls observed: ${STALLS}."
  echo
  echo "| Scenario | Alert / check | Expected | Result |"
  echo "| --- | --- | --- | --- |"
  for row in "${REPORT_ROWS[@]}"; do echo "$row"; done
} > "$REPORT"
green "report written: ${REPORT}"

if [ "${FAILED}" -ne 0 ]; then red "E2E FAILED — see report"; exit 1; fi
green "E2E PASSED — every alert fired and resolved"
