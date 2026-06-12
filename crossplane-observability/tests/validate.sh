#!/usr/bin/env bash
#
# validate.sh — full offline validation for crossplane-observability.
# Run from anywhere:  ./tests/validate.sh
#
# Layers (each fails the script on error):
#   1. helm lint + template render (Phase 1 defaults AND everything enabled)
#   2. promtool check rules     — PromQL parses, rule structure valid
#   3. promtool test rules      — rule LOGIC fires as intended on synthetic series
#   4. metric gate              — every referenced metric is in the allowlist; every
#                                 recording-rule reference resolves (check_metrics.py)
#   5. dashboard JSON           — valid JSON, unique panel ids
#   6. kubeconform (best-effort)— CRDs/manifests schema-check (skips unknown schemas)
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
  --set prometheus.monitors.coreServiceMonitor.enabled=true
  --set prometheus.monitors.providerPodMonitor.enabled=true
  --set upjet.enabled=true
  --set crossplane.inventory.enabled=true
  --set prometheus.rules.fleet.claimNotReady.enabled=true
  --set prometheus.rules.fleet.circuitBreakerDropRatioHigh.enabled=true
  --set prometheus.rules.fleet.circuitBreakerFrequentOpens.enabled=true
  --set prometheus.rules.cloud.cloudAPIThrottling.enabled=true
  --set prometheus.rules.functions.functionLatencyHigh.enabled=true
  --set prometheus.rules.functions.functionErrorRate.enabled=true
  --set prometheus.rules.functions.functionCacheErrorRate.enabled=true
)

run_promtool() {
  if command -v promtool >/dev/null 2>&1; then promtool "$@";
  else docker run --rm -v "${CHART}:/work" -w /work --entrypoint promtool "$PROM_IMAGE" "$@"; fi
}
run_kubeconform() {
  if command -v kubeconform >/dev/null 2>&1; then kubeconform "$@";
  else docker run --rm -i "$KCONF_IMAGE" "$@"; fi
}

mkdir -p "$RENDER_DIR"
trap 'rm -f "${RENDER_DIR}/all.yaml"' EXIT

step "1. helm lint"
helm lint "$CHART"

step "1. helm template (Phase 1 defaults)"
helm template cp "$CHART" >/dev/null && green "renders"

step "1. helm template (everything enabled)"
helm template cp "$CHART" "${ALL_FLAGS[@]}" > "${RENDER_DIR}/all.yaml" && green "renders"

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
if ls "${T}/fixtures/"*-metrics.txt >/dev/null 2>&1; then
  "${T}/capture-metrics.sh" \
    --core "${T}/fixtures/core-metrics.txt" \
    $( [ -f "${T}/fixtures/provider-metrics.txt" ] && echo --provider "${T}/fixtures/provider-metrics.txt" ) \
    -o "${RENDER_DIR}/captured.regenerated.txt" >/dev/null
  # compare metric names only (ignore the dated header)
  if ! diff <(grep -vE '^#|^$' "${T}/metrics-allowlist.captured.txt" | sort) \
            <(grep -vE '^#|^$' "${RENDER_DIR}/captured.regenerated.txt" | sort) >/dev/null; then
    red "metrics-allowlist.captured.txt is OUT OF SYNC with tests/fixtures/."
    red "Re-run ./tests/integration.sh (or capture-metrics.sh) and commit the result."
    exit 1
  fi
  green "captured allowlist matches fixtures"
else
  red "no fixtures found — run ./tests/integration.sh to capture them"; exit 1
fi

step "4b. metric-reality gate (captured fixtures + documented-upstream)"
python3 "${T}/check_metrics.py" \
  --rules "${RENDER_DIR}/all.yaml" \
  --dashboard "${CHART}/files/crossplane_grafana_dashboard.json" \
  --allowlist "${T}/metrics-allowlist.captured.txt" \
  --documented "${T}/metrics-allowlist.documented.txt"

step "5. dashboard JSON"
jq -e . "${CHART}/files/crossplane_grafana_dashboard.json" >/dev/null
DUP=$(jq '[.. | objects | select(has("gridPos")) | .id] | (length) as $n | (unique|length) as $u | $n-$u' "${CHART}/files/crossplane_grafana_dashboard.json")
[ "$DUP" = "0" ] && green "valid JSON, panel ids unique" || { red "duplicate panel ids"; exit 1; }

step "5b. dashboard PromQL parses"
# Extract every panel query and check it as PromQL by wrapping each as a recording rule
# and running promtool check rules. Catches a malformed panel expr (JSON-valid but broken
# PromQL) — which the JSON check above cannot see. Grafana $vars sit inside string
# literals here, so they parse fine.
python3 - "${CHART}/files/crossplane_grafana_dashboard.json" "${RENDER_DIR}/dash-exprs.yaml" <<'PY'
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

step "6. kubeconform (best-effort schema check)"
if helm template cp "$CHART" "${ALL_FLAGS[@]}" | \
   run_kubeconform -strict -ignore-missing-schemas \
     -schema-location default \
     -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
     -summary 2>/dev/null; then green "schema check passed"; else
   red "kubeconform unavailable or reported issues (non-fatal: CRD schemas may be missing)"; fi

echo
green "ALL VALIDATION PASSED"
