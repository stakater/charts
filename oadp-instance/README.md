# OADP Operator Instance

After OADP (OpenShift API for Data Protection) operator is installed, you can deploy OADP instance (DataProtectionApplication) in the same namespace, which defines a AWS s3 bucket as the backup location and run Velero application to perform the backup.

## Prerequisites

1. OADP (OpenShift API for Data Protection) operator is installed
2. The credential to access AWS s3 bucket is created as following pattern. Suggent use SealedSecret to encrypt it before commit to githup repos. If you change the secret name or key, the values of this helm chart should be updated accordingly.

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: cloud-credentials
  namespace: openshift-adp
stringData:
  cloud: |
    [default]
    aws_access_key_id=XXXXXXXXXXXX
    aws_secret_access_key=YYYYYYYYYYY
type: Opaque
```

## Usage

For usage details, please check the manual [here](https://github.com/stakater-ab/handbook/blob/main/src/engineering/sre/backup-and-recovery.md). Additionally, this helm chart doesn't create the VolumeSnapshotClass because of varying cluster setup and requirements. You can use Restic to backup and restore PVCs. If you want to use Volumesnapshot for that purpose, you can create the VolumeSnapshotClass manually.

## Running without a backup location

On a cluster with nowhere to store Velero backups (no S3 bucket), set:

```yaml
clusterBackup:
  enabled: false        # no AwsVeleroBackupBucket claim
backupLocations: []
snapshotLocations: []
externalSecrets:
  enabled: false        # nothing to fetch credentials for
pushSecret:
  enabled: false
configuration:
  velero:
    noDefaultBackupLocation: true
```

The DPA then has no backup storage location, with `noDefaultBackupLocation: true` and `backupImages: false`, which OADP requires together. The `default-object-schedule` Schedule is not rendered. The operator and its plugins stay installed, so anything that brings its own location (for example ODF Regional-DR, which needs the `kubevirt` plugin) still works.

OADP rejects a DPA that sets `noDefaultBackupLocation` and also lists `backupLocations`, and one that sets neither. The chart fails the render in both cases, instead of leaving the DPA to fail at reconcile time.

## Testing

`helm unittest .` runs `tests/*_test.yaml`. CI does not run them yet; run them locally before opening a PR.
