#!/usr/bin/env bash
#
# up.sh — stand up the full e2e stack on kind:
#   kind cluster -> kube-prometheus-stack (Prometheus Operator, Prometheus, Alertmanager, KSM)
#   -> grafana-operator + Grafana + Prometheus datasource -> S3 bucket (SeaweedFS)
#   -> real Velero 1.16.2 in openshift-adp + the OADP-shaped metrics Service
#   -> this chart (monitors, state exporter, rules, dashboard) with values-e2e.yaml
#   -> demo etcd-backup CronJobs (dashboard's optional etcd panels).
# Idempotent. Uses an isolated kubeconfig (see lib.sh). Then run scenarios.sh / screenshots.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
S="${E2E}/stack"

step "1. kind cluster ${CLUSTER}"
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 180s
kind export kubeconfig --name "$CLUSTER" >/dev/null

step "2. kube-prometheus-stack 91.8.2"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community vmware-tanzu >/dev/null
helm --kube-context "$CTX" upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version 91.8.2 -n monitoring --create-namespace -f "${S}/kps-values.yaml" --wait --timeout 10m

step "3. grafana-operator v5.25.0 + Grafana + datasource"
helm --kube-context "$CTX" upgrade --install grafana-operator oci://ghcr.io/grafana/helm-charts/grafana-operator \
  --version 5.25.0 -n grafana-operator --create-namespace --wait --timeout 5m
k apply -f "${S}/grafana.yaml"
k -n grafana wait --for=condition=Available deploy/grafana-deployment --timeout=300s 2>/dev/null || \
  { sleep 20; k -n grafana rollout status deploy/grafana-deployment --timeout=300s; }

step "4. S3 bucket (SeaweedFS 4.48)"
k apply -f "${S}/s3.yaml"
k -n s3 rollout status deploy/seaweedfs --timeout=300s
k -n s3 wait --for=condition=Complete job/create-bucket --timeout=300s

step "5. Velero 1.16.2 in ${NS} + OADP-shaped metrics Service"
helm --kube-context "$CTX" upgrade --install velero vmware-tanzu/velero --version 10.1.3 \
  -n "$NS" --create-namespace -f "${S}/velero-values.yaml" --wait --timeout 10m
k apply -f "${S}/oadp-metrics-service.yaml"
for _ in $(seq 1 30); do
  [ "$(k -n "$NS" get bsl dpa-1 -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ] && break; sleep 5
done
echo "BSL dpa-1: $(k -n "$NS" get bsl dpa-1 -o jsonpath='{.status.phase}')"

step "6. oadp-observability (this chart) with values-e2e.yaml"
helm --kube-context "$CTX" upgrade --install oadp-observability "$CHART" -n "$NS" \
  -f "${E2E}/values-e2e.yaml" --wait --timeout 5m

step "7. demo etcd-backup CronJobs"
k apply -f "${S}/demo-etcd-cronjobs.yaml"

step "8. sanity"
k -n "$NS" get servicemonitor,prometheusrule,grafanadashboard,deploy
green "stack is up. KUBECONFIG=${KUBECONFIG}"
