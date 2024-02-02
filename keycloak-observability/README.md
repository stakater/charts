# Helm chart for Keycloak dashboard


### Pod monitor
Pod monitor is required for EAP metrics and should be included as part of the keycloak deployment
```
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: eap
  namespace: {keycloak instance namespace}
spec:
  selector:
    matchLabels:
      app: sso
  podMetricsEndpoints:
    - targetPort: 9990
```

### Service monitor
Service monitor is required for application metrics and should be included as part of the keycloak deployment
```
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: example-name
  namespace: {keycloak instance namespace}
spec:
  jobLabel: rhsso
  selector:
    matchLabels:
      app: sso
  endpoints:
    - port: sso-monitoring
      path: /metrics
      scheme: https
      tlsConfig:
        insecureSkipVerify: true
      relabelings:
        - targetLabel: job
          replacement: keycloak
        - targetLabel: provider
          replacement: keycloak
        - targetLabel: instance
          replacement: sso
    - port: sso
      path: /auth/realms/master/metrics
      scheme: https
      tlsConfig:
        insecureSkipVerify: true
      relabelings:
        - targetLabel: job
          replacement: keycloak
        - targetLabel: provider
          replacement: keycloak
        - targetLabel: instance
          replacement: sso
```

## Dependencies

1. ???

## Local Development

### Install

```
tilt up
```

### Teardown

```
tilt down -f Tiltfile-delete
```
