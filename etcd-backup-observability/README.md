# Helm chart for etcd Backup dashboard


## Dependencies

1. grafana-operator

## Dashboards

| Dashboard | uid | Shows |
| --- | --- | --- |
| etcdBackupJobs | `etcdBackupJobs` | One namespace at a time: CronJob and Job status for the `type="etcd-backup"` CronJobs. |
| Hosting-cluster backups | `hosting-cluster-backups` | All namespaces: last successful run and last schedule per backup CronJob (hosted-cluster etcd `<name>-etcd-backup`, per-org OpenBao `<org>-bao-openbao-snapshot`), CronJobs that never succeeded, and the backup alerts firing. |

The second dashboard reads kube-state-metrics (`kube_cronjob_status_last_successful_time`,
`kube_cronjob_status_last_schedule_time`) and `ALERTS`, so it needs no extra monitors. Its
`CronJob regex` variable defaults to `.+-etcd-backup|.+-openbao-snapshot`; narrow it to look at one
family. A CronJob that was scheduled but never succeeded has no last-success series, so it is shown
as `NEVER` in the table and counted in the `Never succeeded` tile.

## Local Development

### Install

```
tilt up
```

### Teardown

```
tilt down -f Tiltfile-delete
```