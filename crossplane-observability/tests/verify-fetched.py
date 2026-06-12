#!/usr/bin/env python3
"""
verify-fetched.py — check the chart's referenced metrics against REAL /metrics dumps
captured from a cluster by fetch-cluster-metrics.sh.

For every external metric the rules + dashboard reference, it reports whether the dumps
contain it and prints a sample line (so the actual LABELS can be eyeballed against what the
rules assume). It also checks the specific label *values* the rules filter on
(result="error", result="Dropped", reason="OOMKilled", name=~crossplane).

This is how a "documented" metric graduates to "confirmed in our environment": run it, and
anything PRESENT can move into metrics-allowlist.captured.txt (and the fixtures), while a
mismatch in labels tells you exactly what to fix in the rule before deploying.

Usage:
  python3 tests/verify-fetched.py --dumps <dir-from-fetch-cluster-metrics.sh> \
      [--rules <rendered.yaml>] [--dashboard files/crossplane_grafana_dashboard.json]

If --rules is omitted it renders the chart with everything enabled itself.
"""
import argparse, glob, os, re, subprocess, sys
from check_metrics import metrics_in, load_rule_exprs, load_dashboard_exprs

HERE = os.path.dirname(os.path.abspath(__file__))
CHART = os.path.dirname(HERE)

# Label-value assumptions the rules depend on: metric -> list of substrings that should
# appear on at least one of its sample lines.
LABEL_EXPECTATIONS = {
    "function_run_function_response_total": ['result_severity="Fatal"'],
    "circuit_breaker_events_total": ['result="Dropped"'],
    "kube_pod_container_status_last_terminated_reason": ['reason="OOMKilled"'],
    "aggregator_unavailable_apiservice": ['crossplane'],
    # inventory exporter one-hot condition metric (Story 4.1)
    "kube_customresource_crossplane_xr_xproject_condition": ['type="Ready"', 'status="True"'],
}


def referenced_external(rules_path, dashboard_path):
    exprs, _ = load_rule_exprs(rules_path)
    exprs += load_dashboard_exprs(dashboard_path)
    ext = set()
    for e in exprs:
        for kind, name in metrics_in(e):
            if kind == "metric" and ":" not in name:
                ext.add(name)
    return sorted(ext)


def render_all():
    flags = []
    for k in ["prometheus.monitors.coreServiceMonitor.enabled",
              "prometheus.monitors.providerPodMonitor.enabled", "upjet.enabled",
              "prometheus.rules.fleet.claimNotReady.enabled",
              "prometheus.rules.fleet.circuitBreakerDropRatioHigh.enabled",
              "prometheus.rules.fleet.circuitBreakerFrequentOpens.enabled",
              "prometheus.rules.cloud.cloudAPIThrottling.enabled",
              "prometheus.rules.functions.functionLatencyHigh.enabled",
              "prometheus.rules.functions.functionErrorRate.enabled",
              "prometheus.rules.functions.functionCacheErrorRate.enabled"]:
        flags += ["--set", f"{k}=true"]
    out = subprocess.check_output(["helm", "template", "cp", CHART, *flags], text=True)
    p = os.path.join(HERE, ".rendered"); os.makedirs(p, exist_ok=True)
    fp = os.path.join(p, "all.for-verify.yaml")
    open(fp, "w").write(out)
    return fp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dumps", required=True, help="directory of *.txt metric dumps")
    ap.add_argument("--rules")
    ap.add_argument("--dashboard", default=os.path.join(CHART, "files/crossplane_grafana_dashboard.json"))
    a = ap.parse_args()

    rules = a.rules or render_all()
    referenced = referenced_external(rules, a.dashboard)

    # Index every sample line in the dumps by leading metric name.
    lines_by_metric = {}
    for f in glob.glob(os.path.join(a.dumps, "*.txt")):
        for line in open(f, errors="replace"):
            if line.startswith("#") or not line.strip():
                continue
            m = re.match(r"([a-zA-Z_:][a-zA-Z0-9_:]*)", line)
            if m:
                lines_by_metric.setdefault(m.group(1), []).append(line.rstrip())

    present, absent = [], []
    print(f"# referenced external metrics: {len(referenced)}   dumps: {a.dumps}\n")
    for metric in referenced:
        # histogram refs end in _bucket; the base series may appear as _bucket/_sum/_count
        hits = lines_by_metric.get(metric) or []
        if hits:
            present.append(metric)
            print(f"PRESENT  {metric}")
            print(f"         e.g. {hits[0][:160]}")
            for sub in LABEL_EXPECTATIONS.get(metric, []):
                ok = any(sub in l for l in hits)
                print(f"         label check {sub!r}: {'OK' if ok else 'NOT FOUND — rule filter may be wrong'}")
        else:
            absent.append(metric)
    if absent:
        print("\n# ABSENT from these dumps (different source, or not exercised here):")
        for m in absent:
            print(f"  - {m}")
    print(f"\nSUMMARY: {len(present)} present, {len(absent)} absent, of {len(referenced)} referenced.")
    print("Move PRESENT metrics into metrics-allowlist.captured.txt (and capture fixtures) "
          "once their labels match; fix the rule for any failed label check.")


if __name__ == "__main__":
    sys.exit(main())
