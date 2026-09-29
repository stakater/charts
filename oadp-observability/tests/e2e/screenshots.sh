#!/usr/bin/env bash
#
# screenshots.sh <name> — screenshot the chart's "OADP / Backup Status" dashboard as
# imported by grafana-operator on the kind stack, to docs/images/dashboard-<name>.png.
# Uses headless Google Chrome (or $CHROME) against Grafana's anonymous Viewer access.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NAME="${1:?usage: screenshots.sh <name>}"
OUT="${CHART}/docs/images/dashboard-${NAME}.png"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p "$(dirname "$OUT")"

OWN_PF=0
if ! curl -sf "$GRAFANA/api/health" >/dev/null 2>&1; then
  k -n grafana port-forward svc/grafana-service 13000:3000 >/dev/null 2>&1 & PF=$!; OWN_PF=1
  trap '[ "$OWN_PF" = 1 ] && kill $PF 2>/dev/null || true' EXIT
fi
for _ in $(seq 1 60); do
  curl -sf "$GRAFANA/api/dashboards/uid/oadp-backup-status" >/dev/null 2>&1 && break; sleep 2
done
curl -sf "$GRAFANA/api/dashboards/uid/oadp-backup-status" >/dev/null || { red "dashboard not imported"; exit 1; }

# kiosk: no Grafana chrome; 1h window so the incident + recovery are visible.
URL="$GRAFANA/d/oadp-backup-status/?orgId=1&kiosk&from=now-1h&to=now"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1600,945 --virtual-time-budget=30000 --run-all-compositor-stages-before-draw \
  --screenshot="$OUT" "$URL" >/dev/null 2>&1
[ -s "$OUT" ] && green "wrote $OUT ($(du -h "$OUT" | cut -f1))" || { red "screenshot failed"; exit 1; }
