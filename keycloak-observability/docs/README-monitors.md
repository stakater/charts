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



Edit the cluster-monitoring-config ConfigMap object: https://docs.openshift.com/container-platform/4.12/monitoring/enabling-monitoring-for-user-defined-projects.html

```
$ oc -n openshift-monitoring edit configmap cluster-monitoring-config
```

Add enableUserWorkload: true under data/config.yaml:
```
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true 
```
When set to true, the enableUserWorkload parameter enables monitoring for user-defined projects in a cluster.


File [keycloak-servicemonitor.yml](./keycloak-servicemonitor.yml) contains scrape targets for keycloak.
Metrics listed in [Keycloak metrics](https://github.com/aerogear/keycloak-metrics-spi) will be scraped from all Keycloak nodes.

Create Service Monitor
```
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: keycloak-service-monitor
  namespace: sso
spec:
  endpoints:
    - bearerTokenSecret:
        key: ''
      path: /auth/realms/master/metrics
      port: keycloak
      scheme: https
      tlsConfig:
        ca: {}
        cert: {}
        insecureSkipVerify: true
    - bearerTokenSecret:
        key: ''
      path: /metrics
      port: keycloak-monitoring
      scheme: http
      tlsConfig:
        ca: {}
        cert: {}
        insecureSkipVerify: true
  namespaceSelector: {}
  selector:
    matchLabels:
      app: keycloak
```
