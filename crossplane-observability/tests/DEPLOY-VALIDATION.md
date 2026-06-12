# Deploy-validation brief (for a Claude Code agent)

**You are a Claude Code agent.** An operator has (or is about to) deploy the
`crossplane-observability` chart to a real cluster and wants you to **validate it end-to-end
and return structured feedback**. Produce the report in the exact format in §"Report" so the
feedback is quick to read and comparable across clusters. Do not improvise the format.

You have whatever cluster access the operator gives you (`kubectl`/`oc`, and ideally read
access to their Prometheus/Thanos). If you're missing access for a step, mark that step
`SKIPPED (no access)` in the report — don't guess.

## What this chart is (so your findings are accurate)

A Helm chart of Prometheus alerts + recording rules + a Grafana dashboard for Crossplane,
organised by the 17 user stories in `docs/roadmap.md`. Key facts you must hold:

- Provider state metrics (`crossplane_managed_resource_*`) are **per-GVK counts labelled only
  `gvk`** — not per-resource, no namespace. Per-tenant/claim signal needs the inventory
  exporter (`crossplane.inventory.*`, one-hot `kube_customresource_crossplane_xr_*_condition`).
- Many rules ship **disabled**: Phase-2 (functions/circuit-breaker, need Crossplane 2.2/2.3),
  Upjet (`upjet.enabled`), inventory/claim (`crossplane.inventory.enabled`). Disabled ≠ broken.
- Dashboard/alert thresholds come from `values.yaml` and are **placeholders pending baseline
  calibration** — flagging "too noisy / never fires" is expected, valuable feedback.
- The #1 bug class is **label mismatch** (a metric exists but the rule's `{label=...}` filter,
  `by (...)`, or `{{ $labels.X }}` uses the wrong label). Hunt for it specifically.

## Procedure

Run steps in order. Capture evidence (command + output) for the report.

### 0. Offline sanity (no cluster)
```bash
cd crossplane-observability && ./tests/validate.sh
```
Must print `ALL VALIDATION PASSED`. If not, stop and report a BLOCKER — the chart is broken
before deployment.

### 1. Confirm the deployment
Find the release and namespace (ask the operator or `helm list -A | grep observability`).
```bash
helm get values <release> -n <ns>            # what was actually enabled
kubectl get servicemonitor,podmonitor,prometheusrule,grafanadashboard -n <ns> \
  -l app.kubernetes.io/name=crossplane-observability
```
Expect: 1 core ServiceMonitor, 1 provider PodMonitor, the recording-rule PrometheusRule, the
enabled alert PrometheusRules, and the GrafanaDashboard. Note anything missing/extra.

### 2. Confirm scrape targets are healthy
In Prometheus/UWM, check the chart's targets are `up` and the core metrics exist:
```promql
up{job=~"crossplane.*"}                       # core + providers should be 1
count(crossplane_managed_resource_exists)     # > 0 means provider state metrics flow
```
Target down / metric absent → BLOCKER for everything downstream; record which job.

### 3. Metric reality check against THIS cluster
```bash
./tests/fetch-cluster-metrics.sh -n <ns>
python3 tests/verify-fetched.py --dumps ./fetched-metrics-<ctx>
```
For every referenced metric this prints PRESENT (with a real label line) or ABSENT, and
checks the label values the rules filter on. **Cross-check the printed labels against each
rule** — a PRESENT metric with different labels than the rule assumes is a MAJOR finding (see
the `gvk` precedent). ABSENT for a disabled/phase-2/upjet metric is expected, not a bug.

### 4. Rule health (did Prometheus accept the rules?)
Query the rules API of whatever evaluates them (UWM: thanos-ruler / the user-workload
Prometheus). Example via a port-forwarded endpoint:
```bash
curl -s "$PROM_URL/api/v1/rules" | jq -r '
  .data.groups[].rules[] | select(.health!="ok") |
  "\(.name): health=\(.health) lastError=\(.lastError)"'
```
Any rule with `health != "ok"` or a `lastError` → BLOCKER/MAJOR (usually a label/PromQL
mismatch). Also confirm each **recording rule** produces series:
```promql
crossplane:managed_resource_ready:ratio
crossplane:reconcile_errors:ratio
crossplane:claim_tree_ttr_seconds:p95
```
Empty recording-rule output while inputs exist → the recording expr is wrong **or** (on
OpenShift UWM) namespace enforcement is filtering it out. A rule with `health=ok` that
produces **no series** is the silent-failure case — check the live (UWM-rewritten) query for an
injected `namespace="…"` that doesn't match where the metric's series actually live. This is
exactly how the inventory/composite rules fail on UWM (finding N1): confirm
`crossplane:composite_ready:ratio` actually has series, not just that the rule is healthy.

### 5. Alert sanity
```promql
ALERTS{rulesgroup="crossplane"}               # what is firing/pending right now
```
For each firing alert: is it a true problem or a false positive (threshold too tight)? For
the healthy state, the customer-facing alerts (MRNotReady, ClaimTreeNotReady, APIService
Unavailable) should be quiet. Note any alert that is firing without a real underlying problem
(→ calibration finding) or that you'd expect to fire but doesn't.

### 6. Dashboard
Open the "Crossplane Observability" dashboard (folder from `grafana.folder`). For each
populated row, confirm panels render data (not "No data"/"N/A") and the threshold colours look
right. Expected-empty rows: Phase-2 (Functions, Circuit-breaker), Cloud (Upjet) unless those
are in use. A populated panel showing "No data" → MAJOR (query/label mismatch); record the
panel title.

### 7. Threshold calibration feedback
Compare the `values.yaml` thresholds to observed baseline (from the panels). For each that's
clearly off, record a MINOR calibration finding with the observed range and a suggested value.

## Report

Write the result to `tests/reports/validation-<cluster>-<YYYY-MM-DD>.md` using **exactly** this
structure:

```markdown
# Crossplane Observability — Deploy Validation
- Cluster / context: <name>
- Crossplane version: <x.y.z>   Providers: <list>   Inventory exporter: <yes/no>
- Prometheus: <UWM / kube-prometheus / other>   Access: <full / metrics-only / none>
- Chart values enabled: <monitors, upjet, inventory, phase2 …>
- Date: <YYYY-MM-DD>   Agent run: <commit sha of the branch>
- **Overall verdict: PASS | PASS-WITH-ISSUES | FAIL**

## Story status
| Story | What | Status | Evidence / note |
|---|---|---|---|
| 1.1 | MR ready ratio + MRNotReady | OK / NoData / Misconfigured / Noisy / N/A(disabled) | … |
| 1.2 | TTR / TTRDegraded | … | … |
| 1.3 | Claim-tree p95 / ClaimTreeNotReady | … | … |
| 2.1–2.5 | control-plane | … | … |
| 3.1 | drift | … | … |
| 4.1 | claim/inventory | … | … |
| 4.2 | circuit breaker (Phase 2) | … | … |
| 5.1/5.2 | functions (Phase 2) | … | … |
| 6.1 | upjet cloud | … | … |
| 7.1/7.2 | footprint | … | … |

## Findings
(one block per finding, severity-ordered: BLOCKER > MAJOR > MINOR > NIT)

### [SEVERITY] <short title>
- Story/area: <e.g. 1.1>
- Symptom: <what's wrong, observed>
- Evidence: <command/PromQL + output, or kubectl output, or panel name>
- Likely cause: <e.g. metric label is `gvk` not `kind`>
- Suggested fix: <file path + concrete change>

## Metric reality (live)
<paste the verify-fetched.py summary line + any label mismatches>

## Not validatable here (and why)
<phase-2/upjet/inventory gaps with the reason, so they aren't mistaken for failures>
```

Severity guide: **BLOCKER** = chart doesn't load / core signal dead; **MAJOR** = an enabled
alert or panel is wrong (won't fire / no data / wrong labels); **MINOR** = threshold
calibration, cosmetics with impact; **NIT** = wording/polish.

## Filing issues (optional)

If the operator wants findings as GitHub issues, create one per BLOCKER/MAJOR:
```bash
gh issue create --repo stakater/charts \
  --title "[crossplane-observability] <finding title>" \
  --label crossplane-observability \
  --body "$(printf 'Severity: <SEV>\nStory: <n>\nSymptom: ...\nEvidence:\n```\n<output>\n```\nLikely cause: ...\nSuggested fix: <file> <change>\nFound on: <cluster>, chart <sha>')"
```
Otherwise leave them in the report; the chart-side agent (see HANDOFF.md) will action them.

## Guardrails

- Evidence or it didn't happen — every finding needs a command/query + its output.
- Disabled/Phase-2/Upjet/inventory metrics being absent is **expected**, not a finding.
- If you change chart files to fix something, `./tests/validate.sh` must stay green and you
  must add/adjust a `unit/rules.test.yaml` case. Never weaken the gate to pass.
- A real metric with unexpected labels is the most likely bug — always compare the live label
  line (from verify-fetched.py) to what the rule assumes before concluding it "works".
- Stay within `crossplane-observability/`; this repo is one-chart-per-PR, Rebase-and-Merge.
```
