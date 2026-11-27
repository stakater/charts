#!/usr/bin/env bash
#
# up.sh — reproducible e2e stack: kind + cert-manager + the FULL MTO suite
# (source-built) + kube-prometheus-stack + this chart with values-e2e.yaml.
# Mirrors the capture-lab bring-up the fixtures and dashboard screenshot came
# from; every non-obvious step below was a real finding (see docs/roadmap.md
# "Scrape-surface gaps").
#
# Prerequisites: docker, kind, kubectl, helm, and local checkouts of the four
# operator repos, pointed at by env vars:
#   TENANT_OPERATOR_DIR FINOPS_OPERATOR_DIR HIBERNATION_OPERATOR_DIR TEMPLATE_OPERATOR_DIR
# Private Go modules in tenant/finops builds need GIT_USER/GIT_TOKEN.
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER="${CLUSTER:-mto-obs-e2e}"
: "${TENANT_OPERATOR_DIR:?}" "${FINOPS_OPERATOR_DIR:?}" "${HIBERNATION_OPERATOR_DIR:?}" "${TEMPLATE_OPERATOR_DIR:?}"
CHART="$(cd ../.. && pwd)"
K="kubectl --context kind-${CLUSTER}"

echo "== kind cluster"
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s

echo "== cert-manager"
$K apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml >/dev/null
$K wait --for=condition=available deployment --all -n cert-manager --timeout=5m

echo "== build + load operator images"
( cd "$FINOPS_OPERATOR_DIR"   && GIT_USER="${GIT_USER:-}" GIT_TOKEN="${GIT_TOKEN:-}" make docker-build IMG=finops-operator:e2e )
( cd "$TENANT_OPERATOR_DIR"   && docker build -q --build-arg GIT_USER="${GIT_USER:-}" --build-arg GIT_TOKEN="${GIT_TOKEN:-}" -t tenant-operator:e2e . )
( cd "$HIBERNATION_OPERATOR_DIR" && docker build -q -t hibernation-operator:e2e . )
( cd "$TEMPLATE_OPERATOR_DIR" && docker build -q -t template-operator:e2e . )
for img in finops-operator tenant-operator hibernation-operator template-operator; do
  kind load docker-image "${img}:e2e" --name "$CLUSTER"
done

echo "== postgres (finops + tenant databases)"
$K create ns finops-operator-system 2>/dev/null || true
cat <<'YAML' | $K -n finops-operator-system apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: capture-postgres, labels: {app: capture-postgres}}
spec:
  replicas: 1
  selector: {matchLabels: {app: capture-postgres}}
  template:
    metadata: {labels: {app: capture-postgres}}
    spec:
      containers:
        - name: postgres
          image: postgres:16
          env:
            - {name: POSTGRES_USER, value: finops}
            - {name: POSTGRES_PASSWORD, value: e2e-lab-only}
            - {name: POSTGRES_DB, value: finopsdb}
          ports: [{containerPort: 5432}]
---
apiVersion: v1
kind: Service
metadata: {name: capture-postgres}
spec:
  selector: {app: capture-postgres}
  ports: [{port: 5432}]
YAML
$K -n finops-operator-system rollout status deploy/capture-postgres --timeout=180s

echo "== finops-operator (kustomize; image override beats the pinned digest)"
$K kustomize "$FINOPS_OPERATOR_DIR/config/default" \
  | sed 's|image: ghcr.io/stakater/finops-operator.*|image: docker.io/library/finops-operator:e2e|' \
  | $K apply -f - >/dev/null
$K -n finops-operator-system set env deploy/finops-operator-controller-manager \
  POSTGRES_CONNECTION_STRING='postgresql://finops:e2e-lab-only@capture-postgres.finops-operator-system:5432/finopsdb?sslmode=disable' \
  OPENCOST_CONNECTION_STRING='http://opencost.finops-operator-system:9003' \
  OPENCOST_DEPLOYMENT_NAME=opencost OPENCOST_DEPLOYMENT_NAMESPACE=finops-operator-system \
  OPERATOR_IMAGE=docker.io/library/finops-operator:e2e
$K -n finops-operator-system scale deploy/finops-operator-finops-gateway-gateway --replicas=0 2>/dev/null || true

echo "== hibernation-operator + template-operator-v2"
$K kustomize "$HIBERNATION_OPERATOR_DIR/config/default" \
  | sed 's|image: registry.connect.redhat.com/stakater/hibernation-operator.*|image: docker.io/library/hibernation-operator:e2e|' \
  | $K apply -f - >/dev/null
$K kustomize "$TEMPLATE_OPERATOR_DIR/config/default" \
  | sed 's|image: ghcr.io/stakater/template-operator-v2.*|image: docker.io/library/template-operator:e2e|' \
  | $K apply -f - >/dev/null

echo "== tenant-operator (7 deployments; PLATFORM_TYPE + postgres secret + owner CRB)"
$K create ns multi-tenant-operator 2>/dev/null || true
$K -n finops-operator-system exec deploy/capture-postgres -- psql -U finops -d finopsdb -c 'CREATE DATABASE tenantdb' 2>/dev/null || true
$K -n multi-tenant-operator create secret generic tenant-operator-postgresql \
  --from-literal=POSTGRESQL_SERVICE=capture-postgres.finops-operator-system \
  --from-literal=POSTGRESQL_USER=finops --from-literal=POSTGRESQL_PASSWORD=e2e-lab-only \
  --from-literal=POSTGRESQL_DATABASE=tenantdb --from-literal=POSTGRESQL_PORT=5432 \
  --from-literal=POSTGRESQL_SSL=disable 2>/dev/null || true
$K kustomize "$TENANT_OPERATOR_DIR/config/default" \
  | sed 's|image: registry.connect.redhat.com/stakater/tenant-operator.*|image: docker.io/library/tenant-operator:e2e|' \
  | $K apply -f - >/dev/null
for d in tenant-controller namespace-controller quota-intconfig-controller pilot-controller webhook db-controller extensions-argocd-controller; do
  $K -n multi-tenant-operator set env "deploy/tenant-operator-$d" PLATFORM_TYPE=Kubernetes
done
# Tenant provisioning expects a cluster-level 'owner' CRB to exist.
cat <<'YAML' | $K apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: owner}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin}
YAML

echo "== sample CRs (webhook-admitted; they seed the gauges)"
$K -n finops-operator-system apply \
  -f "$FINOPS_OPERATOR_DIR/config/samples/finops.stakter.com_v1alpha1_finopsprovider-onprem.yaml" \
  -f "$FINOPS_OPERATOR_DIR/config/samples/finops.stakter.com_v1alpha1_pricebook.yaml" \
  -f "$FINOPS_OPERATOR_DIR/config/samples/finops.stakter.com_v1alpha1_costjob.yaml" \
  -f "$FINOPS_OPERATOR_DIR/config/samples/finops.stakter.com_v1alpha1_subscription_costjob.yaml" \
  -f "$FINOPS_OPERATOR_DIR/config/samples/finops_v1alpha1_offering.yaml" >/dev/null
$K apply -f "$HIBERNATION_OPERATOR_DIR/config/samples/hibernation_v1beta1_clusterresourcesupervisor.yaml" >/dev/null
$K apply -f "$TEMPLATE_OPERATOR_DIR/examples/template.yaml" -f "$TEMPLATE_OPERATOR_DIR/examples/templateinstance.yaml" >/dev/null
$K apply -f "$TENANT_OPERATOR_DIR/examples/quota.yaml" -f "$TENANT_OPERATOR_DIR/examples/tenant_v1beta3.yaml" >/dev/null

echo "== privilege the monitoring namespace through MTO's front door"
# MTO's vnamespace webhook denies unlabelled namespaces: add 'monitoring' and
# the operating user to the IntegrationConfig's privileged sets, then create it.
$K -n multi-tenant-operator get integrationconfig tenant-operator-config -o json \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
ac=d['spec']['accessControl']['privileged']
ns=ac.setdefault('namespaces',[])
'^monitoring$' in ns or ns.append('^monitoring$')
us=ac.setdefault('users',[])
'kubernetes-admin' in us or us.append('kubernetes-admin')
json.dump(d,sys.stdout)" | $K replace -f - >/dev/null
sleep 8
$K create ns monitoring 2>/dev/null || true

echo "== kube-prometheus-stack + opencost"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add opencost-charts https://opencost.github.io/opencost-helm-chart >/dev/null 2>&1 || true
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set alertmanager.enabled=false >/dev/null
helm upgrade --install opencost opencost-charts/opencost -n finops-operator-system \
  --set opencost.prometheus.internal.enabled=true \
  --set opencost.prometheus.internal.serviceName=kps-kube-prometheus-stack-prometheus \
  --set opencost.prometheus.internal.namespaceName=monitoring \
  --set opencost.prometheus.internal.port=9090 \
  --set opencost.ui.enabled=false >/dev/null

echo "== the chart under test"
helm upgrade --install mto-observability "$CHART" -n multi-tenant-operator -f "$CHART/tests/e2e/values-e2e.yaml" >/dev/null

echo "== up. Run ./scenarios.sh once targets are healthy (a few minutes)."
