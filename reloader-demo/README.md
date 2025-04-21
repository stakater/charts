# 📦 Workload Demo Helm Chart

This Helm chart simulates a live Kubernetes environment for testing and showcasing **[Stakater Reloader](https://github.com/stakater/reloader)**. It deploys various workloads that watch `ConfigMaps` and `Secrets`, and includes tools to automatically update these resources to trigger reloads and validate the behavior via logs or UI.

---

## 🚀 Features

✅ Forever-running `Deployments`, `StatefulSets`, `DaemonSets`  
✅ Workloads that react to both `ConfigMap` and `Secret` changes  
✅ Periodic updaters for `ConfigMap` and `Secret`  
✅ CronJob to generate and clean up random workloads  
✅ Proper `RBAC` setup for `ServiceAccount`-based permissions  
✅ Works out of the box for **E2E testing**, **live demos**, and **console validation**

---

## 🗂️ Chart Structure Overview

| File | Description |
|------|-------------|
| `Chart.yaml` | Chart metadata |
| `values.yaml` | Default config (image, namespace, schedules, toggles) |
| `templates/configmap.yaml` | Demo `ConfigMap` (`demo-config`) |
| `templates/secret.yaml` | Demo `Secret` (`demo-secret`) |
| `templates/serviceaccount.yaml` | `ServiceAccount` for updater jobs |
| `templates/role.yaml` | `Role` with permissions to manage K8s resources |
| `templates/rolebinding.yaml` | `RoleBinding` to bind role to updater `ServiceAccount` |
| `templates/config-updater-cronjob.yaml` | CronJob to periodically update the `ConfigMap` |
| `templates/secret-updater-cronjob.yaml` | CronJob to periodically update the `Secret` |
| `templates/workload-generator-cronjob.yaml` | CronJob that generates (and cleans up) demo `Deployment`, `StatefulSet`, `DaemonSet`, and `CronJob` |
| `templates/deployment-configmap.yaml` | Long-running Deployment consuming the `ConfigMap` |
| `templates/deployment-secret.yaml` | Long-running Deployment consuming the `Secret` |
| `templates/statefulset.yaml` | StatefulSet consuming the `ConfigMap` |
| `templates/daemonset.yaml` | DaemonSet consuming the `ConfigMap` |
| `templates/cronjob.yaml` | CronJob triggered every 5 mins with configmap annotation |

---

## 🔧 Configuration (via `values.yaml`)

| Key | Description | Default |
|-----|-------------|---------|
| `namespace` | Namespace to install everything in | `reloader-demo` |
| `image.repository` | Demo container image | `alpine` |
| `image.tag` | Image tag | `latest` |
| `configUpdater.enabled` | Toggle ConfigMap updater job | `true` |
| `configUpdater.schedule` | Cron schedule for ConfigMap updater | `*/2 * * * *` |
| `secretUpdater.enabled` | Toggle Secret updater job | `true` |
| `secretUpdater.schedule` | Cron schedule for Secret updater | `*/3 * * * *` |
| `workloadGenerator.enabled` | Toggle random workload generator | `true` |
| `workloadGenerator.schedule` | Cron schedule for workload generation | `*/1 * * * *` |

---

## 🧪 Use Cases

### ✅ E2E Testing

Install with deterministic behavior:

```bash
helm install e2e ./workload-demo -n reloader-demo \
  --set configUpdater.enabled=false \
  --set secretUpdater.enabled=false \
  --set workloadGenerator.enabled=false
```

Manually patch values during test:

```bash
kubectl patch configmap demo-config -n reloader-demo --type merge -p '{"data":{"timestamp":"2025-04-21 10:00:00"}}'
kubectl patch secret demo-secret -n reloader-demo --type merge -p '{"data":{"password":"U0VDUkVU" }}'
```

Use Playwright or API assertions to verify that reloads occurred.

---

### 🎥 Live Demo Mode

Use the defaults to simulate an active system:

```bash
helm install demo ./workload-demo -n reloader-demo
```

- Console will show real-time events.
- Reloads triggered automatically.
- Demo workloads come and go periodically.

---

## 📋 Workloads Summary

| Kind | Name Pattern | Reloads From |
|------|--------------|--------------|
| Deployment | `demo-deployment-configmap` | `ConfigMap` |
| Deployment | `demo-deployment-secret` | `Secret` |
| StatefulSet | `demo-statefulset` | `ConfigMap` |
| DaemonSet | `demo-daemonset` | `ConfigMap` |
| CronJob | `demo-cronjob` | `ConfigMap` |
| Dynamic | `demo-*-$TIMESTAMP` | `ConfigMap` via generator |

---

## 🔐 RBAC Overview

This chart uses a custom `ServiceAccount` (`updater`) with scoped permissions to:

- Patch and update `ConfigMaps` and `Secrets`
- Create and delete `Deployments`, `StatefulSets`, `DaemonSets`, and `CronJobs`

All workloads and jobs are namespace-scoped.

---

## 🧼 Cleanup

```bash
helm uninstall demo -n reloader-demo
kubectl delete ns reloader-demo
```

---

## ❤️ Contribute

This chart is tailored for Stakater Reloader Enterprise testing and visualization. Fork it, customize it, and extend it as needed!

