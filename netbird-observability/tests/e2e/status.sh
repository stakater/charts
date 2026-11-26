#!/usr/bin/env bash
# status.sh — quick look at targets, alerts and rules while the stack runs.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
trap stop_port_forwards EXIT
port_forwards

step "scrape targets (netbird jobs)"
curl -sf "$PROM/api/v1/targets" | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    job = t["labels"].get("job", "")
    if "netbird" in job:
        print(f'"'"'{t["labels"].get("namespace")}/{job}: {t["health"]} ({t["scrapeUrl"]})'"'"')'

step "alerts (any state)"
curl -sf "$PROM/api/v1/alerts" | python3 -c '
import json, sys
alerts = json.load(sys.stdin)["data"]["alerts"]
if not alerts: print("none")
for a in alerts:
    l = a["labels"]
    print(f'"'"'{a["state"]:8} {l.get("alertname")} ns={l.get("namespace")} target={l.get("target", "-")}'"'"')'
