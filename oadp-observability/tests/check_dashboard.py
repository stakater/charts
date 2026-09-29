#!/usr/bin/env python3
"""
check_dashboard.py — assertions on the RENDERED GrafanaDashboard (what grafana-operator
imports), not on the raw JSON files, because the template injects budgets and the optional
etcd section at render time.

Usage: check_dashboard.py <default.yaml> <budget2h.yaml> <etcd.yaml>
  default.yaml  : chart defaults
  budget2h.yaml : --set prometheus.rules.velero.backupStale.maxAgeHours=2
  etcd.yaml     : etcd section enabled with custom namespace/CronJobs/budgets
                  (namespace=backup-x, daily=d-bk, weekly=w-bk, 30h / 100h)
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

default, budget, etcd = (load(p) for p in sys.argv[1:4])

print("default render")
t = by_title(default, "Velero: last successful backup")
check(t is not None and t.get("type") == "table", "Velero status is a TABLE (scales to many schedules)")
check(by_title(default, "Backup storage locations") is not None, "BSL status panel present")
check(not any("kube_cronjob" in e for e in exprs(default)), "no etcd/CronJob query anywhere (etcd section off by default)")
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

print("budget render (maxAgeHours=2)")
r = ranges(status_mapping(budget))
check(any(f == 0 and to == 7200 and txt == "OK" for f, to, txt in r), f"status OK up to 7200s (got {r})")
check(any(f == 7200 and txt == "STALE" for f, to, txt in r), "status STALE from 7200s")
# NEVER is a 1e15 sentinel (not -1) so "worst first" sorting puts never-succeeded on top.
check(any(f <= 1e15 <= to and txt == "NEVER" for f, to, txt in r), "status NEVER for the 1e15 sentinel")
age = by_title(budget, "Velero backup age vs RPO (hours)")
check(age["fieldConfig"]["defaults"]["thresholds"]["steps"][1]["value"] == 2, "age-vs-RPO budget line at 2h")

print("etcd render (enabled, custom names/budgets)")
e = exprs(etcd)
check(by_title(etcd, "etcd daily: last successful backup") is not None, "etcd daily tile present")
check(by_title(etcd, "etcd weekly: last successful backup") is not None, "etcd weekly tile present")
check(any('namespace="backup-x", cronjob="d-bk"' in x for x in e), "daily queries use the configured namespace/CronJob")
check(any('cronjob="w-bk"' in x for x in e), "weekly queries use the configured CronJob")
check(not any("etcd-backup" in x for x in e), "no hardcoded default names leak into a custom config")
dt = by_title(etcd, "etcd daily: last successful backup")["fieldConfig"]["defaults"]["thresholds"]["steps"][1]["value"]
wt = by_title(etcd, "etcd weekly: last successful backup")["fieldConfig"]["defaults"]["thresholds"]["steps"][1]["value"]
check(dt == 108000 and wt == 360000, f"etcd tiles red at the configured budgets (daily {dt}, weekly {wt})")
check("etcd" in by_title(etcd, "Backup alerts firing")["targets"][0]["expr"], "alerts tile includes etcd-backup alerts when enabled")
ids = [p["id"] for p in panels(etcd)]
check(len(ids) == len(set(ids)), "panel ids unique with the etcd section")

sys.exit(1 if errors else 0)
