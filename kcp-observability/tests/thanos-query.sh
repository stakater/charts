#!/usr/bin/env bash
#
# thanos-query.sh — run a PromQL instant query against the cluster's thanos-querier.
# The canonical way to read kcp metrics from a workstation (recorded kcp:* series
# only exist here — UWM evaluates user rules in thanos-ruler, not prometheus).
#
# Usage: ./tests/thanos-query.sh '<promql>'
# Output: raw JSON on stdout (pipe to jq/python).
# Needs: oc login to the cluster.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 '<promql>'" >&2; exit 2; }
HOST=$(kubectl -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}')
TOKEN=$(oc whoami -t)
curl -sk --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "https://${HOST}/api/v1/query" --data-urlencode "query=$1"
