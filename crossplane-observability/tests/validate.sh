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
#   5d. instanceSelector         — an override REPLACES the default instead of unioning with it
#                                 (silent-unimported-dashboard guard)
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

step "5d. grafana instanceSelector is REPLACEABLE — an override must not union with a default"
# Every Grafana CR this chart ships selects its instance by `spec.instanceSelector.matchLabels`,
# which is an AND: one extra key and the CR matches nothing, the dashboard is never imported,
# and Grafana shows no error because no Grafana ever saw the CR. `instanceSelector` is a MAP, so
# a non-empty default in values.yaml DEEP-MERGES with a per-cluster override rather than being
# replaced — a cluster asking for {dashboards: crossplane} would get {app: grafana, dashboards:
# crossplane}. Nulling the default key does not save it either: the KubeStack addon pipeline
# merges a cluster's EnvironmentConfigs with RFC-7386 semantics and CONSUMES the null before
# Helm sees it, resurrecting the default. That is what stuck us-2's addon on 2026-08-20. So
# assert the property directly on rendered output: an override must come back EXACTLY, on every
# Grafana kind, and the unset case must still resolve to the Stakater Cloud default.
python3 - <<'PY_SEL' "$(helm template cp "$CHART" "${ALL_FLAGS[@]}"       --set grafana.instanceSelector.matchLabels.dashboards=crossplane)"     "$(helm template cp "$CHART" "${ALL_FLAGS[@]}")"
import sys, yaml
def selectors(rendered):
    out = {}
    for d in yaml.safe_load_all(rendered):
        if d and str(d.get("kind", "")).startswith("Grafana"):
            out[(d["kind"], d["metadata"]["name"])] = d["spec"].get("instanceSelector")
    return out

overridden, default = selectors(sys.argv[1]), selectors(sys.argv[2])
fail = []
if not overridden:
    fail.append("no Grafana CRs in the render — this guard would pass vacuously")
for key, sel in sorted(overridden.items()):
    want = {"matchLabels": {"dashboards": "crossplane"}}
    if sel != want:
        fail.append(f"{key[0]}/{key[1]}: override did not replace the default — got {sel}, want {want}")
for key, sel in sorted(default.items()):
    want = {"matchLabels": {"app": "grafana"}}
    if sel != want:
        fail.append(f"{key[0]}/{key[1]}: unset selector must resolve to {want}, got {sel}")
if fail:
    for f in fail:
        print("  " + f)
    sys.exit(1)
print(f"{len(overridden)} Grafana CR(s): override replaces cleanly, unset resolves to the default")
PY_SEL
green "instanceSelector overrides replace the default instead of unioning with it"

step "5e. managed-resource counts are DEDUPED — provider replicas must not be summed"
# crossplane_managed_resource_{exists,ready,synced} is a per-GVK COUNT reported independently by
# EVERY replica of the provider serving that GVK. Replicas duplicate the count; they do not shard
# it (verified on eu-2: two provider-aws-s3 pods each report 12 Buckets and the API holds 12). So
# sum() multiplies scaled-out providers by their replica count, and count(x > 0) counts series
# rather than kinds. The error is invisible in the result and uneven across kinds — it hits only
# providers that happen to be scaled out — so it cannot be corrected downstream. Every use must
# dedupe with `max by (gvk)` first. Asserted on rendered rules AND dashboard panel queries.
python3 - <<'PY_MRU' "${RENDER_DIR}/all.yaml" "${CHART}/files/crossplane_grafana_dashboard.json"
import json, re, sys, yaml

GAUGE = re.compile(r"crossplane_managed_resource_(?:exists|ready|synced)\b")
# The metric must open a per-GVK group. Two aggregators are safe and they are safe for different
# reasons:
#   max by (gvk)   — collapses the replicas' identical counts back to the one true value.
#   count by (gvk) — yields one GROUP per gvk, so an outer count() counts kinds. Its VALUE is the
#                    replica count, which is meaningless, so it is only allowed under count().
# `sum by (gvk)` is exactly the bug and must never appear.
DEDUPED = re.compile(r"(max|count)\s+by\s*\(\s*gvk\s*\)\s*\(\s*$")

def check(expr, where, fail):
    for m in GAUGE.finditer(expr):
        opened = DEDUPED.search(expr[:m.start()])
        if not opened:
            fail.append(f"{where}: `{m.group(0)}` is aggregated without `max by (gvk)` -> "
                        f"provider replicas are double-counted\n      {expr.strip()[:150]}")
        elif opened.group(1) == "count" and not expr.lstrip().startswith("count("):
            fail.append(f"{where}: `count by (gvk)` counts SERIES (one per replica); its value is "
                        f"only meaningful under an outer count()\n      {expr.strip()[:150]}")

fail, checked = [], 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "PrometheusRule":
        continue
    for g in d["spec"]["groups"]:
        for r in g["rules"]:
            name = r.get("record") or r.get("alert")
            expr = str(r.get("expr", ""))
            if GAUGE.search(expr):
                checked += 1
                check(expr, f"rule {name}", fail)

dash = json.load(open(sys.argv[2]))
def walk(o):
    global checked
    if isinstance(o, dict):
        for t in (o.get("targets") or []):
            expr = t.get("expr", "")
            if GAUGE.search(expr):
                checked += 1
                check(expr, f"panel {o.get('id')} {o.get('title', '')!r}", fail)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(dash)

if not checked:
    fail.append("no expression used the gauges at all — this guard would pass vacuously")
if fail:
    for f in fail:
        print("  " + f)
    sys.exit(1)
print(f"{checked} expression(s) use the MR count gauges, all deduped with max by (gvk)")
PY_MRU
green "managed-resource counts dedupe provider replicas"

step "5f. MRU panels count CLAIMS only — 1 Claim = 1 MRU"
# Ruled 2026-09-09: an MRU is one Crossplane Claim. The XR a Claim creates is the same unit, so a
# billing query that matches `xr_` families (or `(xr|claim)`) counts every claimed unit twice.
# Every panel in the billing row must match only `kube_customresource_crossplane_claim_` series.
python3 - <<'PY_MRU_CLAIM' "${CHART}/files/crossplane_grafana_dashboard.json"
import json, re, sys
dash = json.load(open(sys.argv[1]))
BAD = re.compile(r"kube_customresource_crossplane_(?:\(xr\|claim\)|xr)_")
fail, checked = [], 0
def check(panel):
    global checked
    for t in (panel.get("targets") or []):
        expr = t.get("expr", "")
        if "kube_customresource_crossplane_" in expr:
            checked += 1
            if BAD.search(expr):
                fail.append(f"panel {panel.get('id')} {panel.get('title', '')!r} counts XRs as MRUs:\n      {expr[:150]}")
# Select by TITLE, not by row: the headline "Billable MRUs" stat lives in the capacity row, and a
# row-scoped check silently skipped it. Any panel that calls itself an MRU / billable figure is
# held to the rule wherever it sits. Grafana lays panels out flat while a row is expanded and
# under row.panels[] while collapsed, so look in both places.
MRU_TITLE = re.compile(r"MRU|billable", re.I)
def panels(items):
    for p in items:
        yield p
        yield from panels(p.get("panels") or [])
for p in panels(dash.get("panels", [])):
    if p.get("type") != "row" and MRU_TITLE.search(str(p.get("title", ""))):
        check(p)
if not checked:
    fail.append("no MRU/billable panel queried the inventory exporter — guard would pass vacuously")
if fail:
    for f in fail:
        print("  " + f)
    sys.exit(1)
print(f"{checked} MRU panel quer(ies) count claim_ series only")
PY_MRU_CLAIM
green "MRU panels count Claims, never XRs"

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
