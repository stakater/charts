# Clone PVC

The clone PVC is designed to copy the contents of one PersistentVolume (PV) to a newly created PersistentVolumeClaim (PVC). Clone pvc is especially useful when migrating PersistentVolumes to a new StorageClass or when you need to resize a PV that belongs to a StorageClass that doesn’t support resizing.

The clone PVC employs a workaround for reclaiming PVs, which is necessary to handle ReadWriteOnce (RWO) PVs. If you're working with a ReadWriteMany (RWX) PV, you can directly run a copy job and attach the Job-Pod to the existing PVC—there's no need to create a new PVC.

Use Cases

- Migrate PVs to different StorageClasses.
- Resize PVs that are using StorageClasses that don’t support resizing.
- Copy data from one PV to another, maintaining data integrity.

## How to Use

### Step-by-Step Process

**1. Clone the Repository:** First, clone the repository that contains the clone PVC.

```bash
git clone https://github.com/stakater/charts

cd clone-pvc
```

**2. Identify the PV to Copy:** Find the PersistentVolume (PV) you wish to copy.

**3. Change PV Reclaim Policy:**: Update the persistentVolumeReclaimPolicy of the PV to Retain.

**4. Get PV Name:**: Retrieve the name of the PV you want to copy.

**5. Deploy the Helm Chart:** Apply the provided Helm chart, specifying:

- The name of the PV in the values file.
- The name, storage class, and size of the new PVC.

**6. Delete the Original PVC:** Delete the old PVC and remove the claim reference from the source PV.

**7. Monitor the Job:** The job will begin copying data from the original PV to the new PVC. The logs may show warnings about the inability to preserve the original file owners, but this is a known limitation due to OpenShift security settings and can be ignored.

**8. Cleanup:** After the data has been copied, the new PVC will be available, and you can remove the Helm chart.

## Rebinding the PV to the Original PVC

Once the data has been copied and the Job has been deleted, you can rebind the PV to the original PVC name. If you're using an inflexible operator, like OpenShift image operator, you may need to perform a "hot swap" with the PVC for the PV to be properly bound.

### Steps to Rebind

**1. Check New PV:** Ensure the new PV has the persistentVolumeReclaimPolicy set to Retain and that the access mode matches the PVC you intend to bind it to.

**2. Remove Claim reference:** Delete the PVC bound to the new PV and remove the `ClaimRef` from the PV.

**3. Prepare PVC YAML:** Copy the YAML definition for the PVC you plan to bind the PV to. Paste it into a file or use OpenShift's "Import YAML" dialog.

**4. Update PVC YAML:** Update the volume name in the PVC YAML to point to your new PV.

**5. Delete PVC and Pod** Delete the application's PVC and pod. Then quickly apply the updated PVC YAML to bind the new PV to the PVC.

**6. Confirm Application:** If successful, your application should now be using the newly copied PV, which is on the new StorageClass.

#### Example Helm Chart Deployment for One-Off Job

To deploy the clone PVC as a one-off job, you can use the following example Helm chart configuration:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: clone-pvc
  namespace: argocd
spec:
  destination:
    namespace: <target-namespace>
    server: https://kubernetes.default.svc
  source:
    path: clone-pvc
    repoURL: ssh://git@github.com:stakater/charts
    targetRevision: master
    helm:
      parameters:
        - name: oldPvName
          value: "<target-pv>"
        - name: newPvcName
          value: "clone-pvc"
        - name: newPvcStorageClass
          value: ""
        - name: newPvcSize
          value: "100Gi"
```

By following this process, you can effectively copy data from an existing PersistentVolume to a new PVC, ensuring the migration to new StorageClasses or resizing needs are met.
