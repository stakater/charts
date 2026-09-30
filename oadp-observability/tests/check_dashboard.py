#!/usr/bin/env python3
"""
check_dashboard.py — assertions on the RENDERED GrafanaDashboard (what grafana-operator
imports), not on the raw JSON files, because the template injects budgets and the optional
etcd section at render time.

Usage: check_dashboard.py <default.yaml> <budget2h.yaml> <values.yaml>
  default.yaml  : chart defaults
  budget2h.yaml : --set prometheus.rules.velero.backupStale.maxAgeHours=2
  values.yaml   : the chart's values.yaml (the chart must carry no etcd knobs)
"""
import json, sys, yaml

def load(path):
    for d in yaml.safe_load_all(open(path)):
        if d and d.get("kind") == "GrafanaDashboard":
            return json.loads(d["spec"]["json"])
    sys.exit(f"no GrafanaDashboard in {path}")

def panels(d):
    out = []
    def walk(ps):
        for p in ps or []:
            out.append(p); walk(p.get("panels"))
    walk(d["panels"]); return out

def exprs(d):
    return [t["expr"] for p in panels(d) for t in p.get("targets", []) if t.get("expr")]

def by_title(d, title):
    for p in panels(d):
        if p.get("title") == title: return p
    return None

errors = []
def check(ok, msg):
    print(("  ok: " if ok else "  FAIL: ") + msg)
    if not ok: errors.append(msg)

default, budget = (load(p) for p in sys.argv[1:3])
values_text = open(sys.argv[3]).read()

print("default render")
t = by_title(default, "Velero: last successful backup")
check(t is not None and t.get("type") == "table", "Velero status is a TABLE (scales to many schedules)")
check(by_title(default, "Backup storage locations") is not None, "BSL status panel present")
check(not any("kube_cronjob" in e for e in exprs(default)), "no CronJob query anywhere")
check(not any("etcd" in (p.get("title") or "").lower() for p in panels(default)), "no etcd panel titles")
alerts = by_title(default, "Backup alerts firing")
check(alerts is not None and "etcd" not in alerts["targets"][0]["expr"], "alerts tile counts only this chart's alerts")
ids = [p["id"] for p in panels(default)]
check(len(ids) == len(set(ids)), "panel ids unique")

def status_mapping(d):
    p = by_title(d, "Velero: last successful backup")
    for o in p["fieldConfig"]["overrides"]:
        if o["matcher"].get("options") != "Status":
            continue
        for prop in o["properties"]:
            if prop["id"] == "mappings":
                return prop["value"]
    return []

def ranges(maps):
    return sorted((m["options"]["from"], m["options"]["to"], m["options"]["result"]["text"])
                  for m in maps if m["type"] == "range")

print("budgets are per schedule (recording rule), not baked into the dashboard")
r = ranges(status_mapping(budget))
check(any(f == 0 and to == 1 and txt == "OK" for f, to, txt in r), f"status OK while age/budget < 1 (got {r})")
check(any(f == 1 and txt == "STALE" for f, to, txt in r), "status STALE from age/budget >= 1")
# NEVER is a 1e15 sentinel (not -1) so "worst first" sorting puts never-succeeded on top.
check(any(f <= 1e15 <= to and txt == "NEVER" for f, to, txt in r), "status NEVER for the 1e15 sentinel")
tbl = by_title(budget, "Velero: last successful backup")
check(sum("oadp:schedule_budget_seconds" in t["expr"] for t in tbl["targets"]) == 2, "table's Status and Budget columns read oadp:schedule_budget_seconds")
age = by_title(budget, "Velero backup age / RPO budget")
check(age is not None and "oadp:schedule_budget_seconds" in age["targets"][0]["expr"], "age chart is age/budget per schedule")
check(age["fieldConfig"]["defaults"]["thresholds"]["steps"][1]["value"] == 1, "age chart's line is at 1 (= the budget)")
check(json.dumps(budget) == json.dumps(default), "maxAgeHours changes the recording rule only; the rendered dashboard is identical")

print("OADP only: etcd backups are a separate mechanism with their own chart")
check("etcd" not in json.dumps(default).lower(), "no etcd anywhere in the rendered dashboard")
check("etcd" not in values_text.lower(), "no etcd values in the chart")
check("etcd" not in alerts["targets"][0]["expr"].lower(), "alerts tile counts only Oadp* alerts")

sys.exit(1 if errors else 0)
