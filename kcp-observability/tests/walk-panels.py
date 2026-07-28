#!/usr/bin/env python3
"""Walk every dashboard panel query against the cluster's thanos-querier.

The live half of the dashboard gate: proves each panel's query returns data (or
fails with a reason) on a real cluster. Used by the deploy-validation loop
(tests/DEPLOY-VALIDATION.md section 5). Needs: oc login.

Usage: python3 tests/walk-panels.py
"""
import json, subprocess, sys, urllib.parse, urllib.request, ssl

CHART = __file__.rsplit("/tests/", 1)[0]
DASH = f"{CHART}/files/kcp_grafana_dashboard.json"

def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()

HOST = sh("kubectl", "-n", "openshift-monitoring", "get", "route", "thanos-querier",
          "-o", "jsonpath={.spec.host}")
TOKEN = sh("oc", "whoami", "-t")
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

dash = json.load(open(DASH))
variables = {}
for v in dash.get("templating", {}).get("list", []):
    cur = v.get("current", {}).get("value") or v.get("query")
    if isinstance(cur, list):
        cur = cur[0] if cur else ".*"
    if not cur or cur in ("$__all", "All"):
        cur = ".*"
    variables[v["name"]] = cur

def substitute(expr):
    expr = expr.replace("$__rate_interval", "5m").replace("$__interval", "5m").replace("$__range", "1h")
    for name, val in variables.items():
        expr = expr.replace("${%s}" % name, val).replace("$%s" % name, val)
    return expr

queries = []
def walk(panels):
    for p in panels:
        for t in p.get("targets", []):
            if t.get("expr"):
                queries.append((p.get("title", "?"), t["expr"]))
        if p.get("panels"):
            walk(p["panels"])
walk(dash.get("panels", []))

ok = empty = err = 0
for title, expr in queries:
    q = substitute(expr)
    url = f"https://{HOST}/api/v1/query?query={urllib.parse.quote(q)}"
    try:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
        d = json.load(urllib.request.urlopen(req, context=CTX, timeout=25))
        if d.get("status") != "success":
            err += 1; print(f"ERROR  | {title} | {d.get('error','?')[:90]}")
        elif d["data"]["result"]:
            ok += 1; print(f"data   | {title} | {len(d['data']['result'])} series")
        else:
            empty += 1; print(f"EMPTY  | {title} | {q[:120]}")
    except Exception as e:
        err += 1; print(f"ERROR  | {title} | {e}")

print(f"\nTOTAL {len(queries)} queries: {ok} with data, {empty} empty, {err} errors")
sys.exit(1 if err else 0)
