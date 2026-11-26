#!/usr/bin/env bash
#
# validate.sh — full offline validation for netbird-observability.
# Run from anywhere:  ./tests/validate.sh
#
# Layers (each fails the script on error):
#   1. helm lint + template render (defaults AND everything enabled)
#   1c. scrape/job coherence    — every metrics Service this chart ships is queried by the
#                                 rules under exactly its name (silent-empty-rules guard)
#   2. promtool check rules     — PromQL parses, rule structure valid
#   3. promtool test rules      — rule LOGIC fires as intended on synthetic series
#   4a. allowlist sync          — committed captured allowlist matches tests/fixtures/
#   4b. metric gate             — every referenced metric is captured or documented
#   5. dashboard JSON           — valid JSON, unique panel ids
#   5b. dashboard PromQL parses — every panel query is valid PromQL
#   5c. datasource binding      — every querying panel binds to a declared datasource
#   5d. instanceSelector        — an override REPLACES the default instead of unioning
#   5e. signal job scoping      — unprefixed signal metrics are never queried without the
#                                 signal job matcher (cross-workload collision guard)
#   6. kubeconform (strict)     — every object validates against a CRD schema (vendored)
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

# The unit tests pin this namespace in their series (tests/unit/rules.test.yaml).
NS=netbird-mesh
ALL_FLAGS=(
  -n "$NS"
  --set prometheus.monitors.management.enabled=true
  --set prometheus.monitors.signal.enabled=true
  --set prometheus.monitors.relay.enabled=true
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

step "1. helm lint"
helm lint "$CHART"

step "1. helm template (defaults)"
helm template nb "$CHART" >/dev/null && green "renders"

step "1. helm template (everything enabled)"
helm template nb "$CHART" "${ALL_FLAGS[@]}" > "${RENDER_DIR}/all.yaml" && green "renders"

step "1c. scrape/job coherence — every shipped metrics Service is queried by the rules"
# UWM derives the `job` label from the Service name, and every rule filters on it: get the
# coupling wrong and the rules render, parse, and match no series forever. The chart uses
# FIXED Service names precisely so this coupling is fleet-stable — assert it on the render.
python3 - "${RENDER_DIR}/all.yaml" <<'PY'
import sys, yaml, re
svcs, jobs = [], set()
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d:
        continue
    if d.get("kind") == "Service":
        svcs.append(d["metadata"]["name"])
    elif d.get("kind") == "PrometheusRule":
        for g in d["spec"]["groups"]:
            for r in g["rules"]:
                jobs.update(re.findall(r'job="([^"]+)"', r.get("expr", "")))
fail = [f'Service/{n} is scraped as job="{n}", which no rule queries' for n in svcs if n not in jobs]
if len(svcs) != 3:
    fail.append(f"expected the 3 component metrics Services in the all-enabled render, got {svcs}")
if fail:
    print("\033[31mscrape/job MISMATCH:\033[0m")
    for f in fail:
        print("  -", f)
    print("  jobs queried by rules:", ", ".join(sorted(jobs)))
    sys.exit(1)
print(f"\033[32mjob labels coherent: Services {svcs} all queried by rules\033[0m")
PY

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
"${T}/generate-allowlist.sh" "${RENDER_DIR}/captured.regenerated.txt" >/dev/null
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
  --dashboard "${CHART}/files/netbird_grafana_dashboard.json" \
  --allowlist "${T}/metrics-allowlist.captured.txt" \
  --documented "${T}/metrics-allowlist.documented.txt"

step "5. dashboard JSON"
jq -e . "${CHART}/files/netbird_grafana_dashboard.json" >/dev/null
DUP=$(jq '[.. | objects | select(has("gridPos")) | .id] | (length) as $n | (unique|length) as $u | $n-$u' "${CHART}/files/netbird_grafana_dashboard.json")
[ "$DUP" = "0" ] && green "valid JSON, panel ids unique" || { red "duplicate panel ids"; exit 1; }

step "5b. dashboard PromQL parses"
# Extract every panel query and check it as PromQL via promtool. Grafana $vars inside
# string literals parse as-is; the interval vars ($__rate_interval) sit in range selectors,
# so they are substituted with a literal duration first.
python3 - "${CHART}/files/netbird_grafana_dashboard.json" "${RENDER_DIR}/dash-exprs.yaml" <<'PY'
import json, sys
dash, out = sys.argv[1], sys.argv[2]
exprs = []
def walk(panels):
    for p in panels or []:
        for t in p.get("targets", []) or []:
            if t.get("expr"): exprs.append(t["expr"].replace("$__rate_interval", "5m").replace("$__interval", "5m"))
        walk(p.get("panels"))
walk(json.load(open(dash)).get("panels", []))
rules = "\n".join(f"    - record: dash_{i}\n      expr: |\n        {e}" for i, e in enumerate(exprs))
open(out, "w").write("groups:\n  - name: dashboard.exprs\n    rules:\n" + rules + "\n")
print(f"extracted {len(exprs)} panel queries")
PY
run_promtool check rules "${P}/tests/.rendered/dash-exprs.yaml" >/dev/null && green "all panel queries parse"

step "5c. dashboard datasource binding — every querying panel resolves to a declared datasource"
# grafana-operator resolves the binding by a blind string replace of "${inputName}" ->
# spec.datasources[].datasourceName. An UNBOUND panel silently falls back to whatever
# Grafana picks first — on a cluster with two Prometheus datasources, a coin flip.
python3 - "${RENDER_DIR}/all.yaml" <<'PY_DS'
import sys, yaml, json, re
dash = None
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "GrafanaDashboard":
        dash = d
if dash is None:
    print("no GrafanaDashboard in the render"); sys.exit(1)

declared = {i["inputName"]: i.get("datasourceName", "") for i in dash["spec"].get("datasources", [])}
model = json.loads(dash["spec"]["json"])
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
        fail.append(f'spec.datasources declares input "{name}" but no panel uses "${{{name}}}"')
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
# instanceSelector is a MAP: a non-empty values default deep-merges with a per-cluster
# override instead of being replaced, matchLabels is an AND, and the dashboard silently
# stops being imported. The default is resolved in a helper, not values — assert both paths.
python3 - <<'PY_SEL' "$(helm template nb "$CHART" "${ALL_FLAGS[@]}" --set grafana.instanceSelector.matchLabels.dashboards=netbird)" "$(helm template nb "$CHART" "${ALL_FLAGS[@]}")"
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
    want = {"matchLabels": {"dashboards": "netbird"}}
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

step "5e. signal metrics are job-scoped — unprefixed names must never be queried bare"
# Standalone signal exports UNPREFIXED metric names (active_peers, registrations_total…).
# Any query without the signal job matcher silently matches every workload that exports
# the same generic name — wrong data, no error. Asserted on rendered rules AND dashboard.
python3 - <<'PY_SIG' "${RENDER_DIR}/all.yaml" "${CHART}/files/netbird_grafana_dashboard.json"
import json, re, sys, yaml

SIGNAL = ["active_peers", "registrations_total", "deregistrations_total",
          "registration_failures_total", "messages_forwarded_total",
          "message_forward_failures_total", "peer_connection_duration_seconds"]
fail, checked = [], 0

def check(expr, where):
    global checked
    for name in SIGNAL:
        for m in re.finditer(rf"\b{name}\b", expr):
            checked += 1
            rest = expr[m.end():]
            sel = rest[1:rest.index("}")] if rest.startswith("{") and "}" in rest else ""
            if 'job="netbird-signal-metrics"' not in sel and "netbird-signal" not in sel:
                fail.append(f"{where}: `{name}` queried without the signal job matcher\n      {expr.strip()[:150]}")

for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "PrometheusRule":
        continue
    for g in d["spec"]["groups"]:
        for r in g["rules"]:
            check(str(r.get("expr", "")), f"rule {r.get('alert') or r.get('record')}")

def walk(panels):
    for p in panels or []:
        for t in (p.get("targets") or []):
            check(t.get("expr", ""), f"panel {p.get('id')} {p.get('title', '')!r}")
        walk(p.get("panels"))
walk(json.load(open(sys.argv[2])).get("panels", []))

if not checked:
    fail.append("no expression used any signal metric — this guard would pass vacuously")
if fail:
    for f in fail:
        print("  " + f)
    sys.exit(1)
print(f"{checked} signal-metric reference(s), all scoped to the signal job")
PY_SIG
green "unprefixed signal metrics are always job-scoped"

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
