# How these fixtures were captured

Real `/metrics` output from the official NetBird v0.75.0 images (the version pinned by the
platform's netbird install), captured 2026-10-30 by running each component in Docker and
scraping `:9090/metrics`:

```bash
# management: minimal management.json (sqlite store, IdP none, see capture-management.json)
docker run -d --name nb-mgmt -p 19090:9090 -p 18080:8080 \
  -v "$PWD/capture-management.json:/etc/netbird/management.json:ro" \
  netbirdio/management:0.75.0 \
  --port 8080 --metrics-port 9090 --log-file console --disable-anonymous-metrics=true

# signal / relay: defaults
docker run -d --name nb-signal -p 19091:9090 netbirdio/signal:0.75.0
docker run -d --name nb-relay  -p 19092:9090 \
  -e NB_EXPOSED_ADDRESS=rel://localhost:33080 -e NB_AUTH_SECRET=test \
  -e NB_LISTEN_ADDRESS=:33080 netbirdio/relay:0.75.0

# exercise the management HTTP API (counters are lazily registered)
for i in 1 2 3; do curl -s localhost:18080/api/users; curl -s localhost:18080/api/peers; done

curl -s localhost:19090/metrics > management-metrics.txt
curl -s localhost:19091/metrics > signal-metrics.txt
curl -s localhost:19092/metrics > relay-metrics.txt
```

## What the capture established (vs the upstream docs)

- `management_grpc_connected_streams` exports as `management_grpc_connected_streams_ratio`.
- The aggregate response-code counter is `management_http_response_counter_code_total`.
- `management_http_request_counter_total` has an aggregate series (no `endpoint` label)
  next to per-endpoint series — totals must filter `endpoint=""`.
- On-cluster (not visible in this docker capture): prometheus-operator's own `endpoint`
  target label renames NetBird's HTTP `endpoint` label to `exported_endpoint` — queries
  touching that label must use the exported name (caught by tests/e2e).
- Most app metrics are LAZILY REGISTERED: this baseline shows none of the gRPC
  sync/login, store, updatechannel, account, signal-app or relay-counter families. Those
  live in `metrics-allowlist.documented.txt` until a capture from a live fleet instance
  (with real peers) promotes them.

## Refresh procedure

Re-run the capture with the new NetBird version, replace the three fixture files, run
`./generate-allowlist.sh`, and re-check that every documented-tier metric still exists
upstream (https://docs.netbird.io/selfhosted/observability).
