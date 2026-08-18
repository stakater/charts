#!/usr/bin/env bash
#
# validate.sh — full offline validation for crossplane-observability.
# Run from anywhere:  ./tests/validate.sh
#
# Layers (each fails the script on error):
#   1. helm lint + template render (Phase 1 defaults AND everything enabled)
#   1c. scrape/job coherence    — the `job` label each shipped monitor produces is the one
#                                 the rules actually query (silent-empty-rules guard)
#   2. promtool check rules     — PromQL parses, rule structure valid
#   3. promtool test rules      — rule LOGIC fires as intended on synthetic series
#   4. metric gate              — every referenced metric is in the allowlist; every
#                                 recording-rule reference resolves (check_metrics.py)
#   5. dashboard JSON           — valid JSON, unique panel ids
#   5c. datasource binding      — every querying panel binds to a datasource the CR declares
#                                 (silent-empty-dashboard guard)
#   6. kubeconform (strict)    — every object validates against a CRD schema (vendored)
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
  --set prometheus.monitors.coreMetricsService.enabled=true
  --set prometheus.monitors.coreServiceMonitor.enabled=true
  --set prometheus.monitors.providerPodMonitor.enabled=true
  --set upjet.enabled=true
  --set crossplane.inventory.enabled=true
  --set grafana.compositeAlerts.enabled=true
  --set grafana.compositeAlerts.datasourceUid=test-thanos-uid
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
  else docker run --rm -v "${CHART}:/work" -w /work "$KCONF_IMAGE" "$@"; fi
}

mkdir -p "$RENDER_DIR"
trap 'rm -f "${RENDER_DIR}/all.yaml" "${RENDER_DIR}/all-fixedjob.yaml"' EXIT

step "1. helm lint"
helm lint "$CHART"

step "1. helm template (Phase 1 defaults)"
helm template cp "$CHART" >/dev/null && green "renders"

step "1. helm template (everything enabled)"
helm template cp "$CHART" "${ALL_FLAGS[@]}" > "${RENDER_DIR}/all.yaml" && green "renders"

step "1c. scrape/job coherence — the monitors this chart ships match the job labels its rules query"
# Prometheus-operator derives the `job` label from the scrape object, and the rules filter on
# it: a ServiceMonitor's job is the SERVICE name, a PodMonitor's is `<namespace>/<name>`. Get
# either wrong and nothing complains — the rules render, validate, parse, and match no series
# forever. That is exactly how the shipped provider default (`crossplane-providers`, a name no
# PodMonitor can produce) stayed broken. So assert both couplings on the rendered output.
python3 - "${RENDER_DIR}/all.yaml" <<'PY'
import sys, yaml, re
svcs, pms, jobs = [], [], set()
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d:
        continue
    k = d.get("kind")
    if k == "Service":
        svcs.append(d["metadata"]["name"])
    elif k == "PodMonitor":
        pms.append(d["metadata"]["namespace"] + "/" + d["metadata"]["name"])
    elif k == "PrometheusRule":
        for g in d["spec"]["groups"]:
            for r in g["rules"]:
                jobs.update(re.findall(r'job="([^"]+)"', r.get("expr", "")))
fail = []
for name in svcs:
    if name not in jobs:
        fail.append(f'Service/{name} is scraped as job="{name}", which no rule queries')
for job in pms:
    if job not in jobs:
        fail.append(f'PodMonitor job="{job}" is queried by no rule (crossplane.providers.job disagrees)')
if not svcs or not pms:
    fail.append(f"expected a Service and a PodMonitor in the all-enabled render, got {len(svcs)}/{len(pms)}")
if fail:
    print("\033[31mscrape/job MISMATCH:\033[0m")
    for f in fail:
        print("  -", f)
    print("  jobs queried by rules:", ", ".join(sorted(jobs)))
    sys.exit(1)
print(f"\033[32mjob labels coherent: Service {svcs} + PodMonitor {pms} all queried by rules\033[0m")
PY

step "2/3. merge rendered PrometheusRules for promtool"
# Rendered with an EXPLICIT crossplane.providers.job, unlike all.yaml above: left at the
# default it derives to `<namespace>/<release>-crossplane-observability-providers`, which
# would pin the unit-test fixtures to this script's release name. The unit tests check rule
# LOGIC, not scrape wiring — step 1c owns the wiring — so a stable job label is what they
# want, and pinning it here exercises the override path too.
helm template cp "$CHART" "${ALL_FLAGS[@]}" \
  --set crossplane.providers.job=crossplane-providers > "${RENDER_DIR}/all-fixedjob.yaml"
python3 - "${RENDER_DIR}/all-fixedjob.yaml" "${RENDER_DIR}/rules.yaml" <<'PY'
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
    $( [ -f "${T}/fixtures/inventory-metrics.txt" ] && echo --inventory "${T}/fixtures/inventory-metrics.txt" ) \
    $( [ -f "${T}/fixtures/live-exercised-metrics.txt" ] && echo --extra "${T}/fixtures/live-exercised-metrics.txt" ) \
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

step "5c. dashboard datasource binding — every querying panel resolves to a declared datasource"
# A dashboard binds panels to a datasource, and grafana-operator resolves that binding by a
# blind string replace of "${inputName}" -> spec.datasources[].datasourceName. Nothing looks
# the datasource up, so an UNBOUND panel silently falls back to whatever Grafana picks first
# — which on a cluster with two Prometheus datasources is a coin flip, and rendered the whole
# dashboard "No data" on eu-2 while the metrics were present all along. So assert the binding
# on the rendered CR + its JSON together: no querying panel may be left to Grafana's choice,
# and the CR's declared inputs must actually be the ones the JSON uses.
python3 - "${RENDER_DIR}/all.yaml" <<'PY_DS'
import sys, yaml, json, re
dash = None
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "GrafanaDashboard":
        dash = d
if dash is None:
    print("no GrafanaDashboard in the render"); sys.exit(1)

declared = {i["inputName"]: i.get("datasourceName", "") for i in dash["spec"].get("datasources", [])}
raw = dash["spec"]["json"]
model = json.loads(raw)
dsvars = {v["name"] for v in model.get("templating", {}).get("list", []) if v.get("type") == "datasource"}

refs, unbound = set(), []
def walk(panels, path="panels"):
    for i, p in enumerate(panels or []):
        where = f"{path}[{i}] id={p.get('id')} title={p.get('title')!r}"
        ds = p.get("datasource")
        queries = bool(p.get("targets"))
        if isinstance(ds, str):
            refs.update(re.findall(r"\$\{([^}]+)\}", ds))
        elif isinstance(ds, dict):
            refs.update(re.findall(r"\$\{([^}]+)\}", json.dumps(ds)))
        elif queries:
            unbound.append(where)
        walk(p.get("panels"), where)
walk(model.get("panels", []))

fail = []
for name in sorted(refs):
    if name not in declared and name not in dsvars:
        fail.append(f'panels reference datasource "${{{name}}}", which is neither a spec.datasources inputName nor a datasource template variable')
for name, value in declared.items():
    if not value:
        fail.append(f'spec.datasources input "{name}" has an empty datasourceName')
    if name not in refs:
        fail.append(f'spec.datasources declares input "{name}" but no panel uses "${{{name}}}" — the mapping is dead code and panels bind elsewhere')
for where in unbound:
    fail.append(f"panel with targets has no datasource, so Grafana picks one: {where}")

if fail:
    for f in fail:
        print("  " + f)
    sys.exit(1)
print(f"{len(refs)} datasource input(s) bound: " + ", ".join(f"${{{n}}} -> {declared.get(n, '<template var>')}" for n in sorted(refs)))
PY_DS
green "every querying panel binds to a declared datasource"

step "6. kubeconform — CRD schema validation (monitors, rules, dashboard)"
# Strict, NO -ignore-missing-schemas: every rendered object must validate against a schema,
# using the CRD schemas vendored under tests/schemas/ (ServiceMonitor/PodMonitor/
# PrometheusRule/GrafanaDashboard) plus the built-in k8s schemas. A new kind without a
# vendored schema fails here — vendor it. Fully offline; no network needed.
run_kubeconform -strict -summary \
  -schema-location default \
  -schema-location "${P}/tests/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "${P}/tests/.rendered/all.yaml"
green "all rendered objects valid against their CRD schemas"

echo
green "ALL VALIDATION PASSED"
