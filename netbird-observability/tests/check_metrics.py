#!/usr/bin/env python3
"""
Metric-reality gate for crossplane-observability.

Extracts every metric name referenced by the chart (PrometheusRule expressions and
GrafanaDashboard panel queries) and checks two things:

  1. EXTERNAL metrics (e.g. crossplane_managed_resource_ready) must appear in
     tests/metrics-allowlist.txt — the ground-truth set captured from a real cluster
     (see tests/capture-metrics.sh). A reference to a metric not in the allowlist fails:
     either it's a typo, or the metric does not exist on the target build.

  2. INTERNAL recording-rule names (contain ':', e.g. crossplane:reconcile_errors:ratio)
     must be DEFINED by one of our own recording rules. This catches dangling references
     between an alert/dashboard and the recording rule it depends on.

This proves *consistency* and *membership*, not that a live query returns data — that is
what the integration test (promtool test + a real scrape) is for. But it makes it
impossible to ship a rule that references a metric nobody has confirmed exists.

Usage:
  python3 check_metrics.py --rules <rendered.yaml> --dashboard <dashboard.json> \
                           --allowlist tests/metrics-allowlist.txt [--list]
"""
import argparse, json, re, sys

# PromQL functions + aggregation operators + keywords. Identifiers in these sets are
# never metric names. Kept explicit so an unknown function surfaces as a "metric" and
# gets caught rather than silently ignored.
PROMQL_FUNCS = {
    "abs","absent","absent_over_time","ceil","changes","clamp","clamp_max","clamp_min",
    "day_of_month","day_of_week","day_of_year","days_in_month","delta","deriv","exp",
    "floor","histogram_quantile","histogram_count","histogram_sum","holt_winters","hour",
    "idelta","increase","irate","label_join","label_replace","ln","log2","log10","minute",
    "month","predict_linear","rate","resets","round","scalar","sgn","sort","sort_desc",
    "sqrt","time","timestamp","vector","year","quantile_over_time","avg_over_time",
    "min_over_time","max_over_time","sum_over_time","count_over_time","stddev_over_time",
    "stdvar_over_time","last_over_time","present_over_time","group",
    # aggregation operators
    "sum","min","max","avg","stddev","stdvar","count","count_values","bottomk","topk",
    "quantile",
}
KEYWORDS = {
    "by","without","on","ignoring","group_left","group_right","offset","bool","and","or",
    "unless","le","inf","nan","start","end","atan2",
}
IGNORE = PROMQL_FUNCS | KEYWORDS

IDENT = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*")
# __name__="x" (exact) or __name__=~"regex" selectors — these reference metrics by name
# from inside a label matcher, so they must be pulled out before clean() strips braces.
NAME_SELECTOR = re.compile(r'__name__\s*(=~|=)\s*"([^"]+)"')


def name_selectors(expr: str):
    """Yield (op, value) for __name__ selectors: op is '=' (exact) or '=~' (regex)."""
    return NAME_SELECTOR.findall(expr)


def clean(expr: str) -> str:
    """Strip the parts of a PromQL expression that are not metric references."""
    expr = re.sub(r'"(?:\\.|[^"\\])*"', " ", expr)      # double-quoted strings
    expr = re.sub(r"'(?:\\.|[^'\\])*'", " ", expr)      # single-quoted strings
    expr = re.sub(r"\{[^}]*\}", " ", expr)               # {label="..."} matchers
    expr = re.sub(r"\[[^\]]*\]", " ", expr)              # [5m] ranges
    # aggregation/vector-matching label lists: by (a,b), without(x), on(y), group_left(z)
    expr = re.sub(
        r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", expr
    )
    return expr


def metrics_in(expr: str):
    """Yield candidate metric names from one expression."""
    s = clean(expr)
    for m in IDENT.finditer(s):
        name = m.group(0)
        # function-position identifier (immediately followed by '(') -> a function call
        rest = s[m.end():]
        if rest.lstrip().startswith("("):
            if name not in IGNORE:
                # an unknown function call we don't recognise - report so it's reviewed
                yield ("func?", name)
            continue
        if name in IGNORE:
            continue
        if name.replace(".", "").isdigit():
            continue
        yield ("metric", name)


def load_rule_exprs(path):
    import yaml
    exprs, defined = [], set()
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if not doc or doc.get("kind") != "PrometheusRule":
                continue
            for g in doc["spec"].get("groups", []):
                for r in g.get("rules", []):
                    if "expr" in r:
                        exprs.append(r["expr"])
                    if "record" in r:
                        defined.add(r["record"])
    return exprs, defined


def load_dashboard_exprs(path):
    exprs = []
    def walk(panels):
        for p in panels or []:
            for t in p.get("targets", []) or []:
                if t.get("expr"):
                    exprs.append(t["expr"])
            if p.get("panels"):
                walk(p["panels"])
    walk(json.load(open(path)).get("panels", []))
    return exprs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", required=True)
    ap.add_argument("--dashboard", required=True)
    ap.add_argument("--allowlist", action="append", default=[],
                    help="CAPTURED metric set (real /metrics from the pinned fixtures). Repeatable.")
    ap.add_argument("--documented", action="append", default=[],
                    help="metrics confirmed in upstream docs but not emitted by the pinned "
                         "rig (different source / Phase 2 / Upjet / not exercised). Repeatable.")
    ap.add_argument("--list", action="store_true", help="print referenced metrics and exit")
    a = ap.parse_args()

    rule_exprs, defined = load_rule_exprs(a.rules)
    dash_exprs = load_dashboard_exprs(a.dashboard)
    all_exprs = rule_exprs + dash_exprs

    external, internal, unknown_funcs = set(), set(), set()
    regex_name_pats = set()
    for e in all_exprs:
        for op, val in name_selectors(e):
            if op == "=~":
                regex_name_pats.add(val)
            else:
                external.add(val)  # exact __name__="x" is just a metric reference
        for kind, name in metrics_in(e):
            if kind == "func?":
                unknown_funcs.add(name)
            elif ":" in name:
                internal.add(name)
            else:
                external.add(name)

    if a.list:
        print("# External metrics referenced (must exist on the cluster):")
        for m in sorted(external):
            print(m)
        print("\n# __name__ regex patterns referenced (must match a real metric):")
        for p in sorted(regex_name_pats):
            print(p)
        print("\n# Internal recording-rule names referenced:")
        for m in sorted(internal):
            print(m)
        return 0

    def load(paths):
        s = set()
        for p in paths:
            for line in open(p):
                line = line.split("#", 1)[0].strip()
                if line:
                    s.add(line)
        return s

    captured = load(a.allowlist)
    documented = load(a.documented)
    known = captured | documented

    errors, doc_hits = [], []
    for m in sorted(external):
        if m in documented and m not in captured:
            doc_hits.append(m)
        elif m not in known:
            errors.append(f"  UNKNOWN METRIC: {m}  (not captured in fixtures, not in documented list — typo, or does not exist)")
    for m in sorted(internal):
        if m not in defined:
            errors.append(f"  DANGLING RECORDING REF: {m}  (referenced but no recording rule defines it)")
    for f in sorted(unknown_funcs):
        errors.append(f"  UNRECOGNISED FUNCTION: {f}  (review: real PromQL function, or a metric typo?)")

    # __name__=~ regex selectors: at least one known metric must match (anchored, like PromQL).
    pattern_hits = []
    for pat in sorted(regex_name_pats):
        try:
            rx = re.compile("^(?:" + pat + ")$")
        except re.error as e:
            errors.append(f"  BAD __name__ REGEX: {pat}  ({e})")
            continue
        matches = [m for m in known if rx.match(m)]
        if not matches:
            errors.append(f"  NO METRIC MATCHES __name__ pattern: {pat}  (typo, or no such metric captured/documented)")
        else:
            pattern_hits.append((pat, len(matches)))

    if doc_hits:
        print(f"DOCUMENTED (real per upstream docs, not emitted by the pinned rig): {len(doc_hits)}")
        for m in doc_hits:
            print(f"  - {m}")
    for pat, n in pattern_hits:
        print(f"PATTERN ok: {pat}  matches {n} known metric(s)")

    if errors:
        print("METRIC CHECK FAILED:")
        print("\n".join(errors))
        return 1
    n_captured = len([m for m in external if m in captured])
    print(f"METRIC CHECK OK: {n_captured}/{len(external)} external metrics CAPTURED in fixtures, "
          f"{len(doc_hits)} documented-upstream, {len(internal)} recording refs resolved.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
