#!/usr/bin/env bash
#
# validate.sh — full offline validation for kcp-observability.
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
  --set prometheus.monitors.shardServiceMonitor.enabled=true
  --set prometheus.monitors.frontProxyServiceMonitor.enabled=true
  --set prometheus.monitors.etcdServiceMonitor.enabled=true
  --set prometheus.monitors.syncAgentPodMonitor.enabled=true
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

step "1. helm lint"
helm lint "$CHART"

step "1. helm template (defaults)"
helm template kcp "$CHART" >/dev/null && green "renders"

step "1. helm template (everything enabled)"
helm template kcp "$CHART" "${ALL_FLAGS[@]}" > "${RENDER_DIR}/all.yaml" && green "renders"

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

step "4b. metric-reality gate (captured fixtures + documented-upstream)"
python3 "${T}/check_metrics.py" \
  --rules "${RENDER_DIR}/all.yaml" \
  --dashboard "${CHART}/files/kcp_grafana_dashboard.json" \
  --allowlist "${T}/metrics-allowlist.captured.txt" \
  --documented "${T}/metrics-allowlist.documented.txt"

step "5. dashboard JSON"
jq -e . "${CHART}/files/kcp_grafana_dashboard.json" >/dev/null
DUP=$(jq '[.. | objects | select(has("gridPos")) | .id] | (length) as $n | (unique|length) as $u | $n-$u' "${CHART}/files/kcp_grafana_dashboard.json")
[ "$DUP" = "0" ] && green "valid JSON, panel ids unique" || { red "duplicate panel ids"; exit 1; }

step "5b. dashboard PromQL parses"
python3 - "${CHART}/files/kcp_grafana_dashboard.json" "${RENDER_DIR}/dash-exprs.yaml" <<'PY'
import json, sys
dash, out = sys.argv[1], sys.argv[2]
exprs = []
def walk(panels):
    for p in panels or []:
        for t in p.get("targets", []) or []:
            if t.get("expr"): exprs.append(t["expr"])
        walk(p.get("panels"))
walk(json.load(open(dash)).get("panels", []))
rules = "\n".join(f"    - record: dash_{i}\n      expr: |\n        {e}" for i, e in enumerate(exprs))
open(out, "w").write("groups:\n  - name: dashboard.exprs\n    rules:\n" + rules + "\n")
print(f"extracted {len(exprs)} panel queries")
PY
run_promtool check rules "${P}/tests/.rendered/dash-exprs.yaml" >/dev/null && green "all panel queries parse"

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
