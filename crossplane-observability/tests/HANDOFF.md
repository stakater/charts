# Handoff: verify the documented metrics against real clusters

**You are a Claude Code agent picking this up cold.** Read this top to bottom before acting.
Your operator has `kubectl` access to one or more real Crossplane clusters; you do not have a
cluster yourself unless they give you a kubeconfig/context. Work with them.

## Background (what this is)

`crossplane-observability` is a Helm chart of Prometheus alerts + recording rules + a Grafana
dashboard for Crossplane, implementing `docs/roadmap.md`. Every metric the rules reference must
be **real** — proven to exist with the **labels the rules assume** — before deploy. We do not
trust metric names from docs alone; we verify against live `/metrics`.

The validation harness lives in `tests/` (read `tests/README.md` for the full model). Two
provenance tiers:

- `tests/metrics-allowlist.captured.txt` — metrics scraped from a pinned ephemeral stack
  (Crossplane 2.3.1 + provider-kubernetes v1.2.1), committed in `tests/fixtures/`.
- `tests/metrics-allowlist.documented.txt` — metrics confirmed in upstream docs but **not yet
  emitted by that rig**. **These are your target.**

`./tests/validate.sh` runs everything offline and must stay green.

## Your goal

For each metric in `tests/metrics-allowlist.documented.txt`, use the operator's real clusters
to (a) confirm it exists, (b) confirm its **label keys and the label *values* the rules filter
on**, then (c) graduate it from documented → captured, OR fix the rule if reality differs.
Finish with `./tests/validate.sh` green and a commit.

### The 17 documented metrics, grouped by what's needed to see them

| Group | Metrics | Needs a cluster that… |
| --- | --- | --- |
| Drift | `crossplane_managed_resource_drift_seconds` | has a provider MR that has drifted |
| Functions (Phase 2) | `function_run_function_seconds_bucket`, `function_run_function_response_total`, `function_run_function_response_cache_{hits,misses,errors}_total` | runs Composition **Functions** |
| Circuit breaker (Phase 2) | `circuit_breaker_events_total`, `circuit_breaker_opens_total` | runs realtime compositions |
| Upjet | `upjet_resource_ttr_bucket`, `upjet_resource_reconcile_delay_seconds_bucket` | runs an **Upjet** provider (provider-upjet-aws/gcp/azure) |
| Platform | `aggregator_unavailable_apiservice`, `container_cpu_cfs_{throttled_,}periods_total`, `container_memory_working_set_bytes`, `kube_pod_container_status_restarts_total`, `kube_pod_container_status_last_terminated_reason` | has Prometheus/Thanos (these are apiserver/cAdvisor/KSM, not Crossplane) |
| Inventory (Story 4.1) | `kube_customresource_crossplane_xr_xproject_condition` | runs an inventory exporter (ksm-crossplane / RSM) — already CAPTURED, see "Special cases" |

## Procedure

1. **Capture from each relevant cluster** (ask the operator to run, or run with their context):
   ```bash
   cd crossplane-observability
   ./tests/fetch-cluster-metrics.sh -n <crossplane-namespace>   # repeat per cluster
   ```
   This scrapes Crossplane core + every provider pod into `fetched-metrics-<ctx>/` and writes
   `PLATFORM-QUERIES.md` (PromQL for the platform metrics — run those in their Prometheus and
   save the output into the folder too).

2. **Verify** each dump:
   ```bash
   python3 tests/verify-fetched.py --dumps ./fetched-metrics-<ctx>
   ```
   It prints each referenced metric as PRESENT (with a real sample line so you see the labels) or
   ABSENT, and checks the label values the rules need (`result="error"`, `result="Dropped"`,
   `reason="OOMKilled"`, `name=~crossplane`). **Read the sample lines carefully.**

3. **For each PRESENT metric, reconcile labels against the rule.** This is the important part —
   see the worked example below. If the rule's `by (...)` grouping, `{label=...}` filter, or
   `{{ $labels.X }}` annotation doesn't match the real labels, **fix the rule and its
   `unit/rules.test.yaml` test**, then re-run `./tests/validate.sh`.

4. **Graduate PRESENT-and-correct metrics to captured.** The cleanest way is to fold a real
   dump into the committed fixtures so the captured allowlist regenerates to include them.
   Practical approach without re-running the kind rig:
   - Append the operator's real sample lines for the new metrics into the appropriate
     `tests/fixtures/*.txt` (core metrics → `core-metrics.txt`; provider metrics →
     `provider-metrics.txt`), OR add a new `fixtures/<source>-metrics.txt` and have
     `capture-metrics.sh` include it.
   - Regenerate: `./tests/capture-metrics.sh --core tests/fixtures/core-metrics.txt --provider tests/fixtures/provider-metrics.txt -o tests/metrics-allowlist.captured.txt`
   - Remove those lines from `tests/metrics-allowlist.documented.txt`.
   - Update `tests/fixtures/CAPTURE.md` to note the additional source/cluster + versions.
   - **Note in the fixture header** which lines were added from a live cluster vs the kind rig.
   - Prefer pinning: if a whole new stack (e.g. an Upjet provider) is now part of the baseline,
     add it to `tests/versions.env` and `tests/integration.sh` so it's reproducible, then
     `./tests/integration.sh` regenerates fixtures the canonical way.

5. **For ABSENT metrics**, leave them in `documented.txt` and note (in the file's per-line
   comment) which clusters you checked and why they're absent (e.g. "no Upjet provider in any
   reachable cluster"). Do not invent or guess.

6. **Re-validate and commit** on this branch (`crossplane-observability`):
   ```bash
   ./tests/validate.sh         # must print ALL VALIDATION PASSED
   git add -A && git commit -m "test(crossplane-observability): verify <group> metrics against live clusters"
   git push
   ```

## Worked example — the bug class to watch for

The roadmap implied `crossplane_managed_resource_ready` was a per-resource `0/1` gauge labelled
`kind`/`name`/`namespace`. The real metric (captured) is a **per-GVK count** labelled only
`gvk`:
```
crossplane_managed_resource_ready{gvk="kubernetes.crossplane.io/v1alpha2, Kind=Object"} 1
```
So the rule was rewritten from `... == 0` (per resource) to a ready/exists **ratio** per `gvk`,
and annotations now use `{{ $labels.gvk }}`. **Expect the same surprises** for the metrics you
verify — especially:
- **Upjet** (`upjet_resource_*`): confirm whether the label is `kind`, `gvk`, or
  group/version/kind split, and whether `ttr`/`reconcile_delay_seconds` are histograms (so the
  `_bucket` series exists) or gauges. `cloud-api-throttling.yaml` and the dashboard's Upjet
  panel currently assume `kind` + `_bucket` — fix if wrong.
- **Functions** (`function_run_*`): confirm the `function_name` label exists and that
  `function_run_function_response_total` has a `result` label whose values include the error
  case (the rule filters `result="error"` — the real value might be `"fatal"`, `"failure"`,
  etc.). Fix `function-error-rate.yaml` accordingly.
- **Circuit breaker**: confirm `circuit_breaker_events_total` has a `result` label with a
  `"Dropped"` value and a `controller` label. Fix `fleet/circuit-breaker.yaml` if not.
- **kube_pod_container_status_last_terminated_reason**: confirm `reason="OOMKilled"` is the real
  value (`provider-pod-oom.yaml`).

## Special cases

- Story 4.1 composite/XR readiness comes from an **inventory exporter** (ksm-crossplane /
  resource-state-metrics), not from Crossplane itself. It is now **captured**: the real
  one-hot condition metric `kube_customresource_crossplane_xr_xproject_condition` is in
  `tests/fixtures/inventory-metrics.txt`, wired via `crossplane.inventory.{conditionMetric,
  readyType,syncedType,job}` with `CompositeNotReady`/`CompositeNotSynced` alerts and a
  `crossplane:composite_ready:ratio` recording rule. It ships **disabled** (set
  `crossplane.inventory.enabled=true` + the right `conditionMetric`/`job`). If a cluster
  exposes a DIFFERENT XR kind (family name `kube_customresource_crossplane_xr_<kind>_condition`)
  or a claim-level metric with a `namespace` label, capture it and adjust `conditionMetric`
  (per-tenant grouping needs a namespace label the current XProject metric lacks).
- Phase-2 metrics (functions, circuit breaker) only exist on Crossplane ≥ 2.2/2.3 AND once a
  composition function actually runs. If the operator's clusters don't run functions, these stay
  documented — that's correct, the alerts ship disabled.

## Guardrails

- Never add a metric to `captured.txt` that you didn't see in a real dump. The whole point is no
  made-up metrics.
- Keep "one concern per file" and the existing values-driven structure.
- Every rule change needs a matching `unit/rules.test.yaml` update; `./tests/validate.sh` is the
  gate. Don't weaken the gate to make it pass.
- This repo publishes **one chart per PR** and merges with **Rebase and Merge** (see top-level
  README). Stay within `crossplane-observability/`.
