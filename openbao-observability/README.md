# openbao-observability

A Helm chart for **SAAP OpenBao** observability, integrated with **OpenShift user-workload monitoring (UWM)**. It is the OpenBao counterpart to [`vault-observability`](../vault-observability) (OpenBao keeps Vault's `vault_*` telemetry names).

It ships two kinds of resource into the OpenBao namespace:

| Resource | Purpose |
| --- | --- |
| `ServiceMonitor` | Scrapes `/v1/sys/metrics` on **every** OpenBao server pod via the headless `openbao-internal` service. |
| `PrometheusRule` (×12) | Alerts on availability, seal/leadership, raft/quorum, request latency, and audit-log failures. One rule per file under `templates/prometheus/rules/openbao/`. |

## Why scrape the headless service

The headless `openbao-internal` service sets `publishNotReadyAddresses: true`, so a **not-ready (e.g. `0/1`) pod stays a scrape target** and `up == 0` fires for it. The default upstream ServiceMonitor targets the `-active` (leader) service only, which would not catch a standby going `0/1` — the failure mode that originally went unalerted.

## Prerequisites

### 1. OpenShift user-workload monitoring enabled

```yaml
# openshift-monitoring/cluster-monitoring-config configmap
data:
  config.yaml: |
    enableUserWorkload: true
```

UWM evaluates these `PrometheusRule`s in `thanos-ruler-user-workload`.

### 2. OpenBao must expose metrics unauthenticated *(server-side change)*

OpenBao's `/v1/sys/metrics` endpoint returns **403** on the active node and **400** on standbys unless the TCP listener allows unauthenticated metrics access. Add this to the listener stanza in the OpenBao server config and roll the StatefulSet:

```hcl
listener "tcp" {
  ...
  telemetry {
    unauthenticated_metrics_access = true
  }
}
```

The top-level `telemetry { prometheus_retention_time, disable_hostname = true }` stanza should also be present.

## Configuration

| Key | Default | Description |
| --- | --- | --- |
| `openbao.name` | `openbao` | Release/fullname of the OpenBao install (drives the ServiceMonitor selector). |
| `openbao.service` | `openbao-internal` | Headless service fronting every server pod. |
| `openbao.replicas` | `3` | Expected HA replica count (drives replica/peer alerts). |
| `prometheus.monitors.serviceMonitor.enabled` | `false` | Create the ServiceMonitor. |
| `prometheus.monitors.serviceMonitor.interval` | `30s` | Scrape interval. |
| `prometheus.monitors.serviceMonitor.tls.*` | `openbao-server-tls` / `ca.crt` / `openbao` | CA secret, key, and serverName for the HTTPS scrape. |
| `prometheus.rules.labels` | `{}` | Extra labels added to every `PrometheusRule`. |
| `prometheus.rules.openbao.<alert>.enabled` | `true` | Toggle an individual alert. |

### Alerts

| Alert | Condition |
| --- | --- |
| `OpenBaoPodDown` | `up == 0` for a server pod |
| `OpenBaoMissingReplicas` | `count(up == 1) < replicas` |
| `OpenBaoAllDown` | no pod reporting `up == 1` |
| `OpenBaoSealed` | `vault_core_unsealed == 0` |
| `OpenBaoNoActiveNode` | no node with `vault_core_active == 1` |
| `OpenBaoLeadershipChurn` | repeated `vault_core_leadership_lost_count` increase |
| `OpenBaoAutopilotUnhealthy` | `vault_autopilot_healthy == 0` |
| `OpenBaoRaftQuorumRisk` | `vault_autopilot_failure_tolerance == 0` |
| `OpenBaoRaftPeersLow` | `vault_raft_peers < replicas` |
| `OpenBaoStandbyLagging` | p99 `vault_raft_leader_lastContact` over threshold |
| `OpenBaoHighRequestLatency` | p99 `vault_core_handle_request` over threshold |
| `OpenBaoAuditLogFailure` | `vault_audit_log_{request,response}_failure` increasing |
