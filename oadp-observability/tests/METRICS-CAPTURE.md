# Metrics capture brief — oadp-observability

**Goal:** a real `/metrics` scrape from the Velero server, so the rules and dashboard are
confirmed against metrics that **actually exist, with the labels they actually have**. Today
the Velero series are pinned from the Velero 1.16 source (`tests/metrics-allowlist.documented.txt`,
with citations). A capture moves them to `tests/fixtures/`, where the metric gate counts them as
*captured*. **This is the release gate.**

The state exporter's series are already captured, by `tests/component/state-exporter.sh`.

**Who runs this:** anyone with read access to `openshift-adp` on a cluster running OADP. Prefer
a cluster where at least one Schedule has run, because failure counters only move once
something is exercised.

## What we need

| Component | Fixture file |
| --- | --- |
| Velero server (Deployment `velero`) | `tests/fixtures/velero-metrics.txt` |

## How to capture

The Velero server serves plain http on `:8085`, so no token is needed:

```bash
NS=openshift-adp
oc -n $NS port-forward deploy/velero 8085:8085 &
curl -s localhost:8085/metrics > tests/fixtures/velero-metrics.txt
kill %1
./tests/generate-allowlist.sh && ./tests/validate.sh
```

**Before committing, remove anything identifying.** This repo is **public**. Keep only metric
names, label names, and values. Replace schedule, BSL, and cluster-specific names with neutral
ones (for example `default-object-schedule` and `dpa-1`). Never commit tokens or hostnames.
`tests/validate.sh` step 0 rejects common internal identifiers, but it isn't a substitute for
reading the file.

## Please also check

1. **Versions:** `oc -n openshift-adp get csv | grep oadp` and the Velero image tag. Is it
   Velero 1.16, as the source pin assumes?
2. **Scrape wiring:** `oc -n openshift-adp get svc,servicemonitor`. Does
   `openshift-adp-velero-metrics-svc` exist with port `monitoring`? Is something else already
   scraping it (a double scrape)? Is the namespace UWM-eligible, i.e. *not* labelled
   `openshift.io/cluster-monitoring=true`?
3. **UWM retention:** check `retention` in `user-workload-monitoring-config`. The rules avoid
   windows longer than 12h.
4. **Never-succeeded shape** (if such a cluster exists): `velero_backup_attempt_total{schedule=…}`
   is present while `velero_backup_last_successful_timestamp{schedule=…}` is absent. That's the
   case `OadpBackupNoSuccessfulBackup` covers.
5. **No BSL metric:** `grep -iE 'storage_location|bsl' tests/fixtures/velero-metrics.txt` should
   return nothing. That's why the state exporter exists.
6. **`last_status` clobbering:** after a failed run, `velero_backup_last_status` should read `1`
   again within about a minute. That's why no rule uses it (`docs/design.md`).
7. **Cardinality:** `grep -c '^velero_csi_snapshot' tests/fixtures/velero-metrics.txt`. The
   ServiceMonitor drops this family.
