#!/usr/bin/env bash
# down.sh — tear the e2e stack down completely.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
kind delete cluster --name "$CLUSTER"
rm -f "$KUBECONFIG"
green "cluster ${CLUSTER} deleted"
