#!/usr/bin/env bash
#
# up.sh — stand up the MetalLB capture/e2e stack on kind:
#   kind cluster (1 cp + 2 workers)
#   -> FRR peer container on the kind docker network (BGP AS 64512, dynamic neighbors, BFD)
#   -> MetalLB (pinned chart) in FRR-K8s mode, metallb-system
#   -> IPAddressPools (bgp + l2), BGPPeer(+BFDProfile), advertisements, sample LB services
# Idempotent. Isolated kubeconfig (see lib.sh). Then run capture.sh (fixtures) and later
# scenarios.sh (alert e2e, once the chart is built).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
S="${E2E}/stack"

step "1. kind cluster ${CLUSTER}"
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config "${S}/kind-config.yaml" --wait 180s
kind export kubeconfig --name "$CLUSTER" >/dev/null

step "2. FRR peer container ${FRR} on the kind network"
KIND_SUBNET="$(kind_subnet)"
[ -n "$KIND_SUBNET" ] || { red "could not determine kind network IPv4 subnet"; exit 1; }
if ! docker ps --format '{{.Names}}' | grep -qx "$FRR"; then
  docker rm -f "$FRR" >/dev/null 2>&1 || true
  docker run -d --name "$FRR" --network kind --privileged \
    quay.io/frrouting/frr:9.1.0 sleep infinity >/dev/null
fi
export FRR_IP="$(frr_ip)" KIND_SUBNET
echo "kind subnet: ${KIND_SUBNET}  frr peer: ${FRR_IP}"
docker cp "${S}/frr/daemons" "$FRR":/etc/frr/daemons
envsubst '${KIND_SUBNET} ${FRR_IP}' < "${S}/frr/frr.conf.tpl" | docker exec -i "$FRR" tee /etc/frr/frr.conf >/dev/null
docker exec "$FRR" sh -c 'touch /etc/frr/vtysh.conf && chown -R frr:frr /etc/frr && /usr/lib/frr/frrinit.sh restart' >/dev/null 2>&1 || true
sleep 3
vtysh 'show running-config' | grep -q 'router bgp 64512' && green "  bgpd up, config loaded" \
  || { red "FRR did not load frr.conf"; vtysh 'show running-config' | head -20; exit 1; }

step "3. MetalLB ${METALLB_CHART_VERSION} (FRR-K8s mode) in ${NS}"
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo update metallb >/dev/null
helm --kube-context "$CTX" upgrade --install metallb metallb/metallb \
  --version "$METALLB_CHART_VERSION" -n "$NS" --create-namespace \
  -f "${S}/metallb-values.yaml" --wait --timeout 10m
k -n "$NS" rollout status ds/metallb-speaker --timeout=300s
k -n "$NS" rollout status ds/metallb-frr-k8s --timeout=300s 2>/dev/null || \
  k -n "$NS" get ds -o name   # name differs across chart versions; show what exists

step "4. pools, BGP peer (+BFD), advertisements"
PFX="$(echo "$KIND_SUBNET" | cut -d. -f1-2)"; export PFX
envsubst '${PFX} ${FRR_IP}' < "${S}/metallb-config.yaml.tpl" | k apply -f -

step "5. sample workload + LoadBalancer services (bgp-pool + l2-pool)"
k apply -f "${S}/workloads.yaml"
k -n default rollout status deploy/echo --timeout=180s
for svc in echo-bgp echo-l2; do
  for _ in $(seq 1 30); do
    IP="$(k -n default get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    [ -n "$IP" ] && { green "  $svc -> $IP"; break; }; sleep 2
  done
  [ -n "$IP" ] || { red "$svc got no external IP"; k -n default describe svc "$svc" | tail -5; exit 1; }
done

step "6. BGP + BFD established on the peer, routes present, data path"
for _ in $(seq 1 30); do
  EST="$(vtysh 'show bgp summary json' | jq '[.ipv4Unicast.peers[]? | select(.state=="Established")] | length')"
  [ "${EST:-0}" -ge 3 ] && break; sleep 2
done
echo "established BGP sessions: ${EST:-0}/3"
[ "${EST:-0}" -ge 3 ] || { red "expected 3 established sessions"; vtysh 'show bgp summary'; exit 1; }
# BFD + the service route arrive a few seconds after session establishment — retry.
for _ in $(seq 1 30); do
  BFD_UP="$(vtysh 'show bfd peers brief' | grep -c ' up' || true)"
  [ "${BFD_UP:-0}" -ge 3 ] && break; sleep 2
done
echo "BFD sessions up: ${BFD_UP:-0}/3"
[ "${BFD_UP:-0}" -ge 3 ] || { red "BFD not up"; vtysh 'show bfd peers brief'; exit 1; }
BGP_IP="$(k -n default get svc echo-bgp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
for _ in $(seq 1 30); do
  vtysh "show ip route ${BGP_IP}/32" | grep -q 'via' && { green "  route to ${BGP_IP} learned via BGP"; break; }
  sleep 2
done
vtysh "show ip route ${BGP_IP}/32" | grep -q 'via' || { red "no BGP route to ${BGP_IP}"; exit 1; }
# data path: curl the BGP service IP from inside the peer (it holds the BGP routes);
# also pokes the L2 IP so layer2 request/response counters move.
L2_IP="$(k -n default get svc echo-l2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
docker exec "$FRR" sh -c "command -v curl >/dev/null && for i in 1 2 3; do curl -so /dev/null -w '%{http_code} ' http://${BGP_IP}/ http://${L2_IP}/; done; echo" \
  || echo "  (no curl in frr image — skipped data-path HTTP check)"

step "7. sanity"
k -n "$NS" get pods -o wide
green "stack is up. KUBECONFIG=${KUBECONFIG}  — next: ./capture.sh"
