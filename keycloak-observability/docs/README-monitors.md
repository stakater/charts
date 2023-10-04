# Prometheus Scrape Targets

This directory contains Prometheus scrape targets.

Check the `spec` of your installed Prometheus custom resource.
In this example, let's assume your Prometheus spec contains the following fields:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  ...
  podMonitorNamespaceSelector: {} # auto discover pod monitors accross all namespaces
  podMonitorSelector:
    matchLabels:
      release: my-prometheus
  ...
  serviceMonitorNamespaceSelector: {} # auto discover service monitors accross all namespaces
  serviceMonitorSelector:
    matchLabels:
      release: my-prometheus
  ...
  version: v2.26.0
```

Given the `matchLabels` fields from the Prometheus spec above, you would need to add the label `release: my-prometheus` to the `PodMonitor` and `ServiceMonitor` objects.

File [keycloak-servicemonitor.yml](./keycloak-servicemonitor.yml) contains scrape targets for keycloak. TLS verify will be skipped by default. To enable TLS verification for scraping, set `spec.endpoints[port=prometheus-tls].tlsConfig.insecureSkipVerify` to false and provide a Kubernetes Secret containing CA cert used for Prometheus.
Metrics listed in [Keycloak metrics](https://github.com/aerogear/keycloak-metrics-spi) will be scraped from all Keycloak nodes.

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: keycloak
spec:
  podMetricsEndpoints:
  - port: prometheus
    interval: 15s
  selector:
    matchLabels:
      app.kubernetes.io/component: keycloak
  namespaceSelector:
    any: true
```

File [keycloak-cluster-operator-podmonitor.yml](./keycloak-cluster-operator-podmonitor.yml) contains a scrape target for the keycloak Cluster Operator.
[The metrics](https://book.kubebuilder.io/reference/metrics.html) emitted by the keycloak Cluster Operator are created by Kubernetes controller-runtime and are therefore completely different from the keycloak metrics.
