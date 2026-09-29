#!/usr/bin/env bash
# status.sh — what the e2e stack sees right now: targets, key series, loaded rules,
# dashboard import, current alerts. Waits (up to 3m) for the chart's rules to load first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
trap stop_port_forwards EXIT
port_forwards || exit 1
n_rules() { curl -s "$PROM/api/v1/rules" | python3 -c 'import json,sys;print(len({r["name"] for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"] if r["name"].startswith("Oadp")}))'; }
for _ in $(seq 1 36); do [ "$(n_rules)" -ge 6 ] && break; sleep 5; done
q() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1"; }
curl -s "$PROM/api/v1/targets?state=active" | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    if t["labels"].get("namespace")=="openshift-adp": print("target:",t["health"], t["labels"].get("job"), t["scrapeUrl"])'
q 'count by (job) (velero_backup_attempt_total)' | python3 -c 'import json,sys;print("velero series by job:",[r["metric"] for r in json.load(sys.stdin)["data"]["result"]])'
q 'kube_customresource_backupstoragelocation_status_phase' | python3 -c 'import json,sys;print("bsl:",[(r["metric"].get("name"),r["metric"].get("phase"),r["metric"].get("namespace"),r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]])'
q 'kube_customresource_schedule_created' | python3 -c 'import json,sys;print("schedules:",[r["metric"].get("schedule") for r in json.load(sys.stdin)["data"]["result"]])'
echo "Oadp rules loaded: $(n_rules)"
curl -s "$GRAFANA/api/dashboards/uid/oadp-backup-status" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("grafana:",d.get("dashboard",{}).get("title"),"| folder:",d.get("meta",{}).get("folderTitle"))'
curl -s "$PROM/api/v1/alerts" | python3 -c 'import json,sys;print("alerts:",[(a["labels"]["alertname"],a["state"],a["labels"].get("target",a["labels"].get("schedule",a["labels"].get("name","")))) for a in json.load(sys.stdin)["data"]["alerts"]])'
