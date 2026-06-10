# Testing & validation

These charts ship a lot of PromQL. **PromQL being valid is not the same as the metrics being
real.** This harness separates the questions and answers each with the right tool, and it is
**self-contained**: routine validation runs fully offline against committed fixtures that were
captured from a real, version-pinned Crossplane. No persistent cluster, nothing made up.

| # | Question | Tool | Proves | Cluster? |
| --- | --- | --- | --- | --- |
| 1 | Do the rules parse / is the PromQL valid? | `promtool check rules` | syntax + structure | no |
| 2 | Does the rule *logic* fire as intended? | `promtool test rules` (`unit/`) | operators, label propagation, recording→alert wiring | no (synthetic series) |
| 3 | Do the referenced metrics *exist*? | `check_metrics.py` + allowlists | every metric is either CAPTURED in real fixtures or DOCUMENTED upstream with a citation; recording-rule refs resolve | no (uses committed fixtures) |
| 4 | Capture the ground truth | `integration.sh` (kind + pinned Crossplane) | the fixtures themselves | yes — only when bumping versions |
| 5 | Does it work once **deployed**? | `DEPLOY-VALIDATION.md` (agent brief) | live objects, scrape health, rule health, dashboard, calibration → a structured report | yes — operator's cluster |

Two agent briefs for cluster work: **`HANDOFF.md`** (verify the documented metrics & graduate
them to captured) and **`DEPLOY-VALIDATION.md`** (validate a real deployment and return a
structured feedback report under `reports/`).

## How "are the metrics real?" is answered

`tests/integration.sh` stands up an **ephemeral** kind cluster with the versions pinned in
`versions.env`, installs Crossplane + provider-kubernetes, creates a real in-cluster Object
(a ConfigMap — no cloud credentials), scrapes the real `/metrics`, writes `tests/fixtures/*.txt`,
and tears the cluster down. Those fixtures are committed. The captured allowlist is **derived
from them**, so layer 3 checks the chart against metrics a real build actually emitted — and
`validate.sh` fails if the committed allowlist drifts from the fixtures.

Every referenced metric must have a **provenance**, split across two files:

- **`metrics-allowlist.captured.txt`** — generated from `fixtures/`. Metrics the pinned build
  actually emitted (the strongest evidence: we scraped them).
- **`metrics-allowlist.documented.txt`** — metrics that are **real per the upstream docs**
  (citation in the file header) but the pinned rig doesn't emit, **each line annotated with
  why** (a different source like cAdvisor/KSM/apiserver; a Phase-2 core metric that needs a
  composition function to run; an Upjet-only metric). These are not guesses — they're sourced.
  The gate reports them as DOCUMENTED so the captured-vs-documented split is always visible.

> **Captured baseline:** Crossplane `2.3.1` + provider-kubernetes `v1.2.1` (see
> `fixtures/CAPTURE.md`). This build emits the `crossplane_managed_resource_*` **state metrics**
> (`exists`, `ready`, `synced`) and the `_first_time_to_*` histograms — all captured. `drift`,
> the `function_run_*` / `circuit_breaker_*` core metrics, and `upjet_*` are documented-upstream
> and move to captured once the rig exercises their code path (a drift, a Function, an Upjet
> provider).

## Run everything (no cluster)

```bash
./tests/validate.sh
```

helm lint + template → merge rules → `promtool check rules` → `promtool test rules` →
captured-allowlist-in-sync check → metric gate (captured + documented) → dashboard JSON →
kubeconform. `promtool`/`kubeconform` are used from `$PATH` if present, else via Docker.

## Verify against YOUR running clusters

To confirm the documented metrics exist in your real environment (and that their labels
match what the rules assume), capture from a cluster you have `kubectl` access to:

```bash
./tests/fetch-cluster-metrics.sh -n crossplane-system     # scrapes core + providers
python3 tests/verify-fetched.py --dumps ./fetched-metrics-<ctx>
```

`verify-fetched.py` reports every referenced metric as PRESENT (with a sample line so the
labels are visible) or ABSENT, and checks the specific label values the rules filter on
(`result="error"`, `result="Dropped"`, `reason="OOMKilled"`, …). Platform metrics
(apiserver/cAdvisor/KSM) aren't on Crossplane endpoints — `fetch-cluster-metrics.sh` writes a
`PLATFORM-QUERIES.md` with the PromQL to run against your Prometheus/Thanos to confirm those.
Anything PRESENT (with matching labels) can move into the fixtures + captured allowlist.

## Re-capture fixtures (only when bumping versions)

```bash
# edit tests/versions.env, then:
./tests/integration.sh           # ephemeral kind, capture, teardown
./tests/integration.sh --keep    # leave the cluster up to inspect
# review & commit: tests/fixtures/* and tests/metrics-allowlist.captured.txt
```

To graduate a DOCUMENTED metric to CAPTURED, extend `integration.sh` with the stack its
annotation names (e.g. add an Upjet provider for the `upjet_*` family, or a
Composition+Function for `function_run_*`), re-run, and move the lines to the captured set.

## Files

| File | Purpose |
| --- | --- |
| `validate.sh` | Offline orchestrator for all layers. |
| `versions.env` | Pinned kind / Crossplane / provider versions. |
| `integration.sh` | Ephemeral capture → `fixtures/` + captured allowlist. |
| `capture-metrics.sh` | Extract metric names from `/metrics` dumps (used by integration.sh). |
| `check_metrics.py` | Metric gate: captured + documented membership, dangling-recording-ref check. `--list` to enumerate. |
| `metrics-allowlist.captured.txt` | Generated from fixtures — do not hand-edit. |
| `metrics-allowlist.documented.txt` | Referenced metrics that are real per upstream docs but not emitted by the rig, each with a citation/reason. |
| `fixtures/*.txt` | Real Prometheus exposition from the pinned stack. |
| `unit/rules.test.yaml` | promtool unit tests (firing + non-firing + recording values). |

## Adding a rule

1. Add the rule under `templates/prometheus/rules/<area>/` and its values block.
2. New metric? It must end up in **captured** (exercise it in `integration.sh`) or
   **documented** (with an upstream citation + reason it isn't captured). Don't invent names.
3. Add/extend a `unit/` test (a firing case and a negative case).
4. `./tests/validate.sh` must pass.

## CI

`.github/workflows/crossplane-observability-validate.yaml`:

- **static** (every PR touching the chart): full `validate.sh` against committed fixtures.
- **integration-capture** (manual + weekly): re-runs `integration.sh` and fails if
  `fixtures/` or the captured allowlist drift from what's committed — catches a pinned
  upstream changing under us, and is how a version bump is regenerated.
