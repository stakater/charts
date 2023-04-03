# Mattermost instance

This chart contains the installation process for mattermost instance

**Pre-req**:

- Create a namespace `mattermost-operator`
- Minio should be installed
- Postgres/Mysql should be installed
- Mattermost operator should be installed.
- It can be installed via [helm chart](https://github.com/mattermost/mattermost-helm/tree/master/charts/mattermost-operator)

Below is the sample installation for [mattermost-operator-0.3.1](https://github.com/mattermost/mattermost-helm/tree/mattermost-operator-0.3.1/charts/mattermost-operator)

```yaml
helm repo add mattermost https://helm.mattermost.com
helm install mattermost-operator mattermost/mattermost-operator -n mattermost-operator
```

You can also clone the chart and override the following values

```yaml
mattermostOperator:
  enabled: true
  replicas: 1
  rbac:
    create: true
  serviceAccount:
    create: true
  env:
    maxReconcilingInstallations: 20
    requeuOnLimitDelay: 20s
  image:
    repository: mattermost/mattermost-operator
    tag: v1.18.0
    pullPolicy: IfNotPresent
  args:
    - --enable-leader-election
```