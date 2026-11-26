#!/usr/bin/env bash
#
# up.sh — stand up the full e2e stack on kind:
#   kind cluster -> kube-prometheus-stack (Prometheus Operator, Prometheus, Alertmanager, KSM)
#   -> grafana-operator + Grafana + "prometheus" datasource
#   -> TWO real NetBird v0.75.0 instances (management+signal+relay) in mesh-a and mesh-b
#   -> this chart installed in BOTH namespaces with values-e2e.yaml
#      (the fleet dashboard is enabled on the mesh-a install only, as in production)
# Idempotent. Uses an isolated kubeconfig (see lib.sh). Then run scenarios.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
S="${E2E}/stack"

step "1. kind cluster ${CLUSTER}"
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 180s
kind export kubeconfig --name "$CLUSTER" >/dev/null

step "2. kube-prometheus-stack 91.8.2"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm --kube-context "$CTX" upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version 91.8.2 -n monitoring --create-namespace -f "${S}/kps-values.yaml" --wait --timeout 10m

step "3. grafana-operator v5.25.0 + Grafana + datasource"
helm --kube-context "$CTX" upgrade --install grafana-operator oci://ghcr.io/grafana/helm-charts/grafana-operator \
  --version 5.25.0 -n grafana-operator --create-namespace --wait --timeout 5m
k apply -f "${S}/grafana.yaml"
k -n grafana wait --for=condition=Available deploy/grafana-deployment --timeout=300s 2>/dev/null || \
  { sleep 20; k -n grafana rollout status deploy/grafana-deployment --timeout=300s; }

step "4. two real NetBird ${NS_A} + ${NS_B} instances (v0.75.0: management, signal, relay)"
for ns in "$NS_A" "$NS_B"; do
  sed "s/__NS__/${ns}/g" "${S}/netbird-instance.yaml" | k apply -f -
done
for ns in "$NS_A" "$NS_B"; do
  k -n "$ns" rollout status deploy/netbird-management --timeout=300s
  k -n "$ns" rollout status deploy/netbird-signal --timeout=180s
  k -n "$ns" rollout status deploy/netbird-relay --timeout=180s
done

step "5. netbird-observability (this chart) in both namespaces"
# One install per instance namespace, as on the platform. The fleet dashboard ships from
# exactly one install (mesh-a); mesh-b runs monitors+rules only.
helm --kube-context "$CTX" upgrade --install netbird-observability "$CHART" -n "$NS_A" \
  -f "${E2E}/values-e2e.yaml" --wait --timeout 5m
helm --kube-context "$CTX" upgrade --install netbird-observability "$CHART" -n "$NS_B" \
  -f "${E2E}/values-e2e.yaml" --set grafana.dashboard.enabled=false --wait --timeout 5m

step "6. sanity"
for ns in "$NS_A" "$NS_B"; do k -n "$ns" get servicemonitor,prometheusrule,svc,deploy; done
green "stack is up. KUBECONFIG=${KUBECONFIG}"
