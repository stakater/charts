#!/usr/bin/env bash
#
# validate.sh — full offline validation for oadp-observability (harness from kcp-observability).
# Run from anywhere:  ./tests/validate.sh
#
# Layers (each fails the script on error):
#   1. helm lint + template render (defaults AND everything enabled)
#   2. promtool check rules     — PromQL parses, rule structure valid
#   3. promtool test rules      — rule LOGIC fires as intended on synthetic series
#   4. metric gate              — every referenced metric is captured in fixtures or
#                                 documented-with-citation; recording refs resolve
#   5. dashboard JSON + PromQL  — valid JSON, unique panel ids, every query parses
#   6. kubeconform (strict)     — every object validates against a vendored CRD schema
#
# promtool/kubeconform run from a local binary if present, else via Docker.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
T="${CHART}/tests"
RENDER_DIR="${T}/.rendered"
PROM_IMAGE="prom/prometheus:latest"
KCONF_IMAGE="ghcr.io/yannh/kubeconform:latest"
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
step()  { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }

ALL_FLAGS=(
  --set prometheus.monitors.veleroServiceMonitor.enabled=true
  --set stateExporter.enabled=true
)

run_promtool() {
  if command -v promtool >/dev/null 2>&1; then promtool "$@";
  else docker run --rm -v "${CHART}:/work" -w /work --entrypoint promtool "$PROM_IMAGE" "$@"; fi
}
run_kubeconform() {
  if command -v kubeconform >/dev/null 2>&1; then kubeconform "$@";
  else docker run --rm -v "${CHART}:/work" -w /work "$KCONF_IMAGE" "$@"; fi
}

mkdir -p "$RENDER_DIR"
trap 'rm -f "${RENDER_DIR}/all.yaml"' EXIT

step "0. public-repo hygiene (this repo is PUBLIC)"
# No internal identifiers: ticket keys, cluster codes, private repos/PR refs, incident
# specifics, credentials fields. Internal context belongs in the private tracker, not here.
# This script and vendored upstream CRDs are excluded (the patterns themselves live here).
HYGIENE='\b[A-Z][A-Z0-9]+-[0-9]{2,}\b|\b(eu|us|ap|sa|me|af|ca)-[0-9]+\b|atlassian\.net|gitops-(non)?prod|\b[a-z0-9-]+#[0-9]+\b|kube-?ward|kubestack|secretAccessKey'
if HITS=$(grep -rn -I -E "$HYGIENE" "$CHART" --exclude=validate.sh --exclude-dir=crds --exclude-dir=.rendered); then
  red "internal identifiers found in a public chart:"; echo "$HITS" | head -40
  echo "... $(echo "$HITS" | wc -l | tr -d ' ') line(s)"; exit 1
fi
green "no internal identifiers"

step "1. helm lint"
helm lint "$CHART"

step "1. helm template (defaults)"
helm template oadp "$CHART" >/dev/null && green "renders"

step "1. helm template (everything enabled)"
helm template oadp "$CHART" "${ALL_FLAGS[@]}" > "${RENDER_DIR}/all.yaml" && green "renders"

step "2/3. merge rendered PrometheusRules for promtool"
python3 - "${RENDER_DIR}/all.yaml" "${RENDER_DIR}/rules.yaml" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
groups = {}  # name -> rules[]  (merge same-named groups across CRs into one file)
for d in yaml.safe_load_all(open(src)):
    if not d or d.get("kind") != "PrometheusRule":
        continue
    for g in d["spec"]["groups"]:
        groups.setdefault(g["name"], []).extend(g["rules"])
out = {"groups": [{"name": n, "rules": r} for n, r in groups.items()]}
yaml.safe_dump(out, open(dst, "w"), sort_keys=False)
print(f"merged {len(out['groups'])} groups, {sum(len(r) for r in groups.values())} rules")
PY

# Path prefix differs: a local promtool uses host paths; the Docker fallback sees the
# chart mounted at /work.
if command -v promtool >/dev/null 2>&1; then P="${CHART}"; else P="/work"; fi

step "2. promtool check rules"
run_promtool check rules "${P}/tests/.rendered/rules.yaml"

step "3. promtool test rules (logic)"
run_promtool test rules "${P}/tests/unit/rules.test.yaml"

step "4a. captured allowlist is in sync with committed fixtures"
"${T}/generate-allowlist.sh" -o "${RENDER_DIR}/captured.regenerated.txt" >/dev/null
if ! diff <(grep -vE '^#|^$' "${T}/metrics-allowlist.captured.txt" | sort) \
          <(grep -vE '^#|^$' "${RENDER_DIR}/captured.regenerated.txt" | sort) >/dev/null; then
  red "metrics-allowlist.captured.txt is OUT OF SYNC with tests/fixtures/."
  red "Re-run ./tests/generate-allowlist.sh and commit the result."
  exit 1
fi
green "captured allowlist matches fixtures"

step "4c. every alert's runbook_url resolves to a heading in docs/runbook.md"
python3 - "${RENDER_DIR}/all.yaml" "${CHART}/docs/runbook.md" <<'PY2'
import re, sys, yaml, os
rendered, runbook = sys.argv[1], sys.argv[2]
def slug(h):  # GitHub heading anchor
    return re.sub(r"[^a-z0-9 _-]", "", h.strip().lower()).replace(" ", "-")
heads = set()
if os.path.exists(runbook):
    heads = {slug(m.group(1)) for m in re.finditer(r"^#{1,6}\s+(.+)$", open(runbook).read(), re.M)}
missing = set()
for d in yaml.safe_load_all(open(rendered)):
    if not d or d.get("kind") != "PrometheusRule": continue
    for g in d["spec"]["groups"]:
        for r in g["rules"]:
            url = r.get("annotations", {}).get("runbook_url", "")
            if "alert" in r and "#" not in url:
                missing.add(f"{r['alert']} (no runbook_url)")
            elif "#" in url and url.split("#", 1)[1] not in heads:
                missing.add(f"{r['alert']} -> #{url.split('#',1)[1]}")
if missing:
    print("RUNBOOK GAPS:"); [print("  " + m) for m in sorted(missing)]; sys.exit(1)
print(f"all runbook anchors resolve ({len(heads)} headings)")
PY2

step "4b. metric-reality gate (captured fixtures + documented-upstream)"
DASH="${CHART}/files/oadp_grafana_dashboard.json"
DASH_ETCD="${CHART}/files/oadp_grafana_dashboard_etcd.json"
DASH_ARGS=(); [ -f "$DASH" ] && DASH_ARGS=(--dashboard "$DASH" --dashboard "$DASH_ETCD")
python3 "${T}/check_metrics.py" \
  --rules "${RENDER_DIR}/all.yaml" "${DASH_ARGS[@]+"${DASH_ARGS[@]}"}" \
  --allowlist "${T}/metrics-allowlist.captured.txt" \
  --documented "${T}/metrics-allowlist.documented.txt"

step "5a. rendered dashboard: Velero status table, budgets, optional etcd section"
R="${RENDER_DIR}"
helm template oadp "$CHART" -s templates/grafana/oadp-dashboard.yaml > "$R/dash-default.yaml"
helm template oadp "$CHART" -s templates/grafana/oadp-dashboard.yaml \
  --set prometheus.rules.velero.backupStale.maxAgeHours=2 > "$R/dash-budget.yaml"
helm template oadp "$CHART" -s templates/grafana/oadp-dashboard.yaml \
  --set grafana.dashboard.etcdBackup.enabled=true --set grafana.dashboard.etcdBackup.namespace=backup-x \
  --set grafana.dashboard.etcdBackup.dailyCronJob=d-bk --set grafana.dashboard.etcdBackup.weeklyCronJob=w-bk \
  --set grafana.dashboard.etcdBackup.dailyMaxAgeHours=30 --set grafana.dashboard.etcdBackup.weeklyMaxAgeHours=100 \
  > "$R/dash-etcd.yaml"
python3 "${T}/check_dashboard.py" "$R/dash-default.yaml" "$R/dash-budget.yaml" "$R/dash-etcd.yaml" \
  || { red "rendered dashboard checks failed"; exit 1; }
green "rendered dashboard checks pass"

if [ -f "$DASH" ]; then
step "5. dashboard JSON"
jq -e . "$DASH" >/dev/null && jq -e . "$DASH_ETCD" >/dev/null
DUP=$(jq '[.. | objects | select(has("gridPos")) | .id] | (length) as $n | (unique|length) as $u | $n-$u' "$DASH")
[ "$DUP" = "0" ] && green "valid JSON, panel ids unique" || { red "duplicate panel ids"; exit 1; }

step "5b. dashboard PromQL parses"
python3 - "$DASH" "${RENDER_DIR}/dash-exprs.yaml" "$DASH_ETCD" <<'PY'
import json, sys
dash, out, extra = sys.argv[1], sys.argv[2], sys.argv[3]
exprs = []
def walk(panels):
    for p in panels or []:
        for t in p.get("targets", []) or []:
            if t.get("expr"):
                # Grafana substitutes these before querying; promtool cannot parse them raw.
                e = t["expr"]
                for v in ("$__rate_interval", "$__interval", "$__range"):
                    e = e.replace(v, "5m")
                exprs.append(e)
        walk(p.get("panels"))
walk(json.load(open(dash)).get("panels", [])); walk(json.load(open(extra)).get("panels", []))
rules = "\n".join(f"    - record: dash_{i}\n      expr: |\n        {e}" for i, e in enumerate(exprs))
open(out, "w").write("groups:\n  - name: dashboard.exprs\n    rules:\n" + rules + "\n")
print(f"extracted {len(exprs)} panel queries")
PY
# NOT `cmd && green`: set -e does not apply inside && lists, so a parse failure used to
# print FAILED and still pass the gate (bug inherited from kcp-observability's harness).
if ! run_promtool check rules "${P}/tests/.rendered/dash-exprs.yaml" >/dev/null; then
  red "dashboard PromQL does not parse"; exit 1
fi
green "all panel queries parse"

else
  step "5. dashboard"; green "no dashboard — skipped"
fi

step "6. kubeconform — CRD schema validation (monitors, rules, dashboard)"
# Strict, NO -ignore-missing-schemas: every rendered object must validate against a schema,
# using the CRD schemas vendored under tests/schemas/ plus the built-in k8s schemas.
run_kubeconform -strict -summary \
  -schema-location default \
  -schema-location "${P}/tests/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "${P}/tests/.rendered/all.yaml"
green "all rendered objects valid against their CRD schemas"

echo
green "ALL VALIDATION PASSED"
