# NetBird observability runbook

Each alert's `runbook_url` points at its section here. Every alert carries the instance's
`namespace` — that is *which customer/organization's mesh* is affected. First move for any
alert: open the "NetBird Fleet Observability" dashboard and select that namespace.

Component roles, so impact statements below make sense:

- **management** — control plane: peer login/sync, network map, HTTP API. Down ⇒ peers
  cannot (re)connect or receive config; established tunnels keep forwarding.
- **signal** — connection negotiation between peers. Down ⇒ no NEW peer-to-peer
  connections; established ones keep working.
- **relay** — fallback data path for peers behind hard NAT. Down ⇒ those peers lose
  connectivity; directly-connected peers unaffected.

## NetBirdTargetDown

The component's scrape target exists but fails (`up == 0`): the pod is down, not ready, or
the metrics listener is unreachable.

1. `kubectl -n <ns> get pods,deploy` — crashloop, OOM, pending?
2. `kubectl -n <ns> logs deploy/<management|signal|relay deployment>` — management most
   commonly fails on its store (PostgreSQL down ⇒ check the namespace's CNPG cluster) or
   on a bad `management.json` after a config change.
3. Mind the blast radius while it's down: every other alert that needs this component's
   metrics is disarmed.

## NetBirdMetricsAbsent

The `up` series itself vanished — monitoring is blind, nothing else on this instance can
fire. This is a monitoring-wiring alert, not a workload alert.

1. `kubectl -n <ns> get svc,servicemonitor | grep netbird` — were the chart's metrics
   Service / ServiceMonitor deleted (e.g. by an Argo prune)?
2. `kubectl -n <ns> get endpoints netbird-<component>-metrics` — empty endpoints means the
   pod selector no longer matches (did the netbird install's pod labels change?) or the
   deployment is scaled to 0.
3. If the component was removed on purpose, disable its monitor in this chart's values so
   the watchdog disarms instead of paging.

## NetBirdPeersDisconnected

The instance HAD connected peers recently and now has zero open Sync streams, while
management itself is still scrapable: the peer-facing path is broken, not the pod.

1. Check the management LoadBalancer Service and its external IP/DNS record.
2. Check the management TLS certificate (peers refuse an expired/mismatched cert; the
   in-cluster scrape doesn't use it, so monitoring stays green while peers fall off).
3. `kubectl -n <ns> logs deploy/<management>` for TLS/gRPC listener errors.
4. Correlate with `NetBirdManagementRequestsBlocked`: a reconnect storm after recovery can
   rate-limit peers back out — consider the account's peer count vs the limiter.

## NetBirdManagementApiErrorRateHigh

The HTTP API (dashboard, Crossplane provider, bootstrap automation) returns 5xx.

1. `kubectl -n <ns> logs deploy/<management>` — the 500's stack trace names the cause;
   store errors point at PostgreSQL (CNPG cluster health, disk).
2. Check whether a recent `management.json` change (IdP endpoints!) broke a dependency.
3. 401/403 spikes do NOT fire this alert — those are callers with bad credentials.

## NetBirdManagementApiLatencyHigh / NetBirdManagementSyncLatencyHigh

The API (admin path) or peer Sync (peer path) slowed down.

1. If `NetBirdManagementStoreSlow` fires alongside ⇒ database-bound: go to the CNPG
   cluster (cloudnative-pg-observability) for the postgres-side cause.
2. Otherwise check management CPU/memory (throttling at limits) and the account's peer
   count — network-map computation grows with peers; consider more resources.

## NetBirdManagementRequestsBlocked

The built-in rate limiter has been rejecting login/sync requests for the whole window.

1. Look for the storm's trigger: management/signal restart, LB flap, mass peer reboot
   (e.g. node pool roll in the customer's infra).
2. If the account legitimately outgrew the limiter, raise management's limits; don't
   silence the alert — blocked peers are locked out in waves.

## NetBirdManagementStoreSlow

Management's writes to PostgreSQL are slow — this is the *correlation* alert: it tells you
peer-visible symptoms on this instance are database-bound.

1. Open the namespace's CNPG cluster in cloudnative-pg-observability: WAL, storage
   latency, connections, replication.
2. Check the postgres PVC's storage class performance and fill level.

## NetBirdSignalRegistrationFailures

Peers cannot register on the signal stream ⇒ no new peer-to-peer connections.

1. `kubectl -n <ns> logs deploy/<signal>` — auth/TLS errors dominate here.
2. Check the signal TLS certificate and the LB the peers dial.

## NetBirdPodRestarting

A component container is crashlooping — the cause behind a flapping `NetBirdTargetDown`.

1. `kubectl -n <ns> logs <pod> --previous` — the crash reason is in the previous
   container's last lines (bad config after a change, missing secret, store unreachable).
2. If `NetBirdPodOOM` fires alongside, it is a memory-bound crashloop: go there.
3. A crashloop right after a rollout points at the change — diff the release.

## NetBirdPodOOM

The container was OOM-killed recently. For management this is the expected way an
instance outgrows its sizing: memory grows with the account's peer count.

1. Raise the container's memory limit in the netbird install's values; check the
   instance's peer count trend on the dashboard to size it.
2. A repeating OOM at stable peer count is a leak — capture heap/metrics before and
   after restart and compare, consider pinning the previous image.
3. The alert resolves once the container runs a full window without dying.

## NetBirdPodCPUThrottled

The container spends a high share of CFS periods throttled: its CPU limit is
under-provisioned. Peers experience this as slow logins/syncs long before anything fails.

1. Raise (or remove) the CPU limit for the component in the netbird install's values.
2. Check whether the latency alerts (`NetBirdManagementSyncLatencyHigh`,
   `NetBirdManagementApiLatencyHigh`) confirm user-visible impact — throttling without
   impact at low traffic can wait for the next sizing pass.

## NetBirdSignalForwardFailures

A high share of signal messages fail to forward (target peer offline, send error).

1. If `NetBirdPeersDisconnected` or a peer-count drop coincides: peers trying to reach a
   cohort that fell off — chase that alert instead.
2. Otherwise check signal resources and logs; sustained failures with stable peer counts
   point at signal itself.
