# Metrics capture brief — kcp-observability

**Goal:** get a real `/metrics` scrape from each kcp component so the chart's rules and dashboard
are built against metrics that **actually exist, with the labels they actually have** — not
assumptions. This is the same discipline that saved crossplane-observability from fabricated
metrics. Nothing gets written into a rule until it appears in `tests/fixtures/`.

**Who runs this:** whoever has cluster access to the kcp control plane (you or the colleague's
agent). Output is a handful of text files committed under `tests/fixtures/`.

---

## What we need (one raw scrape per component)

kcp is several apiserver-like processes. Capture `/metrics` from **each**, kept in separate files
so we can see which series belong to which component:

| Component | Fixture file | Why |
| --- | --- | --- |
| A shard (root shard) | `tests/fixtures/shard-metrics.txt` | apiserver + etcd + workqueue + kcp-specific |
| Front-proxy | `tests/fixtures/front-proxy-metrics.txt` | the customer edge — confirm request metric shape |
| Cache server (if standalone) | `tests/fixtures/cache-server-metrics.txt` | replication/cache series |
| etcd | `tests/fixtures/etcd-metrics.txt` | disk / leader / db-size |
| A virtual-workspace apiserver (if standalone) | `tests/fixtures/virtual-workspace-metrics.txt` | APIExport serving |

If a component is embedded in the shard (not a separate target), say so — that itself answers an
open question. Don't fabricate a file for something that isn't a distinct target.

## How to capture

kcp components serve `/metrics` on their secured port (bearer token required, like a
kube-apiserver). Two easy ways — pick whichever your access allows:

**Option 1 — `kubectl get --raw` (simplest if you have a kubeconfig to the shard):**

```bash
# against a shard's apiserver
kubectl get --raw /metrics > shard-metrics.txt
```

**Option 2 — port-forward + curl with a token:**

```bash
# find the component pod/service, then:
kubectl -n <kcp-namespace> port-forward <pod-or-svc> 6443:6443 &
TOKEN=$(kubectl create token <serviceaccount-with-metrics-access> -n <ns>)   # or an existing token
curl -sk -H "Authorization: Bearer $TOKEN" https://localhost:6443/metrics > shard-metrics.txt
```

> **Secrets by reference:** do **not** paste the token into any committed file, chat, or the
> fixture. The fixtures are metric text only. Redact any token/hostname that sneaks into a
> `# HELP`/label line before committing.

Raw Prometheus exposition format (what `/metrics` returns) is exactly what we want — keep the
`# HELP` / `# TYPE` lines, they document each metric.

## Please also answer these inline (paste answers into the PR or alongside the fixtures)

These are the load-bearing unknowns from `docs/roadmap.md` — the answers decide whole capability
areas:

1. **Do kcp apiserver request metrics carry a workspace / logical-cluster label?** Grep one:
   `grep '^apiserver_request_total' shard-metrics.txt | head`. Is there a `cluster=` /
   `logical_cluster=` / `workspace=` label, or not? (Decides per-tenant request observability.)
2. **Workspace lifecycle:** grep for anything workspace-ish:
   `grep -iE 'workspace|logicalcluster|logical_cluster' shard-metrics.txt`. Is there a phase/
   count/lifecycle metric? If nothing native, we'll need a kube-state-metrics custom-resource
   config (like the crossplane inventory exporter) — flag that.
3. **Front-proxy metric shape:** does `front-proxy-metrics.txt` contain `apiserver_request_*`,
   or a proxy-specific family (grep for `proxy`)? 
4. **Separate targets?** Are cache server and virtual workspaces distinct scrape targets, or
   embedded in the shard? 
5. **kcp-specific series:** `grep -E '^kcp_' shard-metrics.txt | sort -u` — paste the list (this
   is the surface we can't guess).

## What happens next (my side)

1. I fold each fixture into `tests/fixtures/` and regenerate `tests/metrics-allowlist.captured.txt`.
2. Every roadmap metric tagged `[std]` gets confirmed (exact labels) or corrected against the dump.
3. Every `[kcp?]` metric either graduates to captured (real name pinned) or its story is deferred
   with a note — never faked.
4. Then, and only then, I build the recording rules, alerts, and dashboard, each behind the
   offline gate (`tests/validate.sh`).
