#!/usr/bin/env bash
# down.sh — tear the capture/e2e stack down completely.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
step "deleting kind cluster ${CLUSTER} + FRR peer ${FRR}"
kind delete cluster --name "$CLUSTER" 2>/dev/null || true
docker rm -f "$FRR" >/dev/null 2>&1 || true
rm -f "$KUBECONFIG"
green "gone"
