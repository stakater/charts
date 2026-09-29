#!/usr/bin/env bash
# down.sh — delete the e2e kind cluster and its isolated kubeconfig.
source "$(dirname "$0")/lib.sh"
kind delete cluster --name "$CLUSTER"
rm -f "$KUBECONFIG"
