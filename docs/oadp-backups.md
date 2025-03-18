# Backing up with Konveyor with OADP

## Introduction
The purpose of this document is to demonstrate a possible backup strategy for obtaining quiesced and consistent backups of Konveyor.

Backing up Konveyor with OADP is relatively straight forward, although it does require some planning.

In order to quiesce databases and ensure consistent backups the easiest approach is to scale down the pods that make up the Konveyor application. We can then use datamover to backup the PVCs in addition to the Kubernetes and OpenShift resources that make up Konveyor. Unfortunately datamover currently requires a storageclass with the `Immediate` volume binding mode if we want to backup PVCs for an application while the pods are scaled down. This requirement should be alleviated in a future release of OADP, but for now the practical affect of this is that we must restrict Konveyor to running pods in a single availability zone. If we try to use the immediate volume binding mode do not take care pods can be launched on a node in a different availability zone than the PVC and will fail to start.

## Install Konveyor

- Prepare a single AZ StorageClass
The process will vary depending on your storage provider. For AWS this can be achieved with the EBS CSI driver, by cloning the gp3-csi storageclass, specifying the allowed topologies, and updating the volumeBinding Mode.
```
cat << EOF | oc create -f -
allowVolumeExpansion: true
allowedTopologies:
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values:
    - us-west-2a
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-csi-konveyor
parameters:
  encrypted: "true"
  type: gp3
provisioner: ebs.csi.aws.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
```
- Install the Konveyor Operator
- Annotate the namespace with a node selector
`oc annotate namespace konveyor-tackle openshift.io/node-selector1=topology.kubernetes.io/zone=us-west-2a`
- Create a tackle CR that makes use of the new storage class
```
cat << EOF | oc create -f -
apiVersion: tackle.konveyor.io/v1alpha1
kind: Tackle
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  cache_storage_class: gp3-csi-konveyor
  feature_auth_required: "true"
  hub_bucket_storage_class: gp3-csi-konveyor
  rwo_storage_class: gp3-csi-konveyor
EOF
```

After a few moments we should have a working install of Konveyor that is pinned to a single availability zone.

## Install OpenShift OADP
- Install the OADP Operator from OperatorHub
- Create a cloud secret with the credentials for your backup location.
The format of this file will vary. For AWS and other S3 storage options it will take the form of a standard aws credential file.
```
[default]
aws_access_key_id = 
aws_secret_access_key = 
```
Once the file is created use it to generate the secret.
`oc create secret generic cloud-credentials --namespace openshift-adp --from-file cloud=cloud-credentials` 
- Create a dpa resource with data mover enabled
```
cat << EOF | oc create -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: velero
  namespace: openshift-adp
spec:
  backupLocations:
  - velero:
      config:
        profile: default
        region: us-west-2
      credential:
        key: cloud
        name: cloud-credentials
      default: true
      objectStorage:
        bucket: konveyor-backups
        prefix: velero
      provider: aws
  configuration:
    nodeAgent:
      enable: true
      uploaderType: kopia
    velero:
      defaultPlugins:
      - openshift
      - aws
      - kubevirt
      - csi
      defaultSnapshotMoveData: true
      defaultVolumesToFSBackup: false
      featureFlags:
      - EnableCSI
EOF
```

## Running Backups
We must take care to shut down the pods, run the backup, and bring the pods back up. Once possible way to achieve this is to run a cronjob that performs these actions.

- The CronJob will run with a serviceaccount. In the example below I named it job-runner.
```
oc create sa job-runner
```

- Grant OADP NS Permissions
The job-runner SA will need to be able to create and monitor resources in the openshift-adp namespace so we give it permission to do so.
```
oc project openshift-adp
oc adm policy add-role-to-user admin -z job-runner
```

- Grant Konveyor NS Permissions
The job-runner SA will also need to shutdown, start, and monitor resources in the konveyor-tackle namespace so, once again give it permission to do so
```
oc project konveyor-tackle
oc adm policy add-role-to-user admin system:serviceaccount:openshift-adp:job-runner
```

- Create a CronJob
Note that the time is cluster time, which by default is UTC.

The RHSSO operator will fail to reconcile if we restore either the `prometheusrules.monitoring.coreos.com` or `servicemonitors.monitoring.coreos.com` resource due to missing ownerRefs. In turn the Konveyor Operator will also fail to reconcile. We can avoid this problem by excluding the resources from the backup and allowing the RHSSO operator to recreate them.

```
apiVersion: batch/v1
kind: CronJob
metadata:
  name: konveyor-backup
  namespace: openshift-adp 
spec:
  schedule: "30 16 * * 1-5"
  concurrencyPolicy: Allow
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: konveyor-backup
            image: registry.redhat.io/openshift4/ose-cli:latest
            command:
              - bash
              - -c
              - |
                oc scale -n konveyor-tackle deployment tackle-operator --replicas=0
                oc wait -n konveyor-tackle po -l name=tackle-operator --for=delete
                oc scale -n konveyor-tackle deployment tackle-keycloak-sso --replicas=0
                oc wait -n konveyor-tackle po -l app.kubernetes.io/name=tackle-keycloak-sso --for=delete
                oc scale -n konveyor-tackle deployment tackle-keycloak-postgresql-15 --replicas=0
                oc wait -n konveyor-tackle po -l app.kubernetes.io/name=tackle-keycloak-postgresql-15 --for=delete
                oc scale -n konveyor-tackle deployment tackle-ui --replicas=0
                oc wait -n konveyor-tackle po -l app.kubernetes.io/name=tackle-ui --for=delete
                oc scale -n konveyor-tackle deployment tackle-hub --replicas=0
                oc wait -n konveyor-tackle po -l app.kubernetes.io/name=tackle-hub --for=delete
                export BACKUP_DATE=$(date +%Y-%m-%d-%H-%M-%S)
                cat << EOF | oc apply -f -
                kind: Backup
                apiVersion: velero.io/v1
                metadata:
                  name: konveyor-backup-$BACKUP_DATE
                  namespace: openshift-adp
                spec:
                  excludedResources:
                  - prometheusrules.monitoring.coreos.com
                  - servicemonitors.monitoring.coreos.com
                  csiSnapshotTimeout: 30m0s
                  defaultVolumesToFsBackup: false
                  includedNamespaces:
                  - konveyor-tackle
                  itemOperationTimeout: 30h0m0s
                  snapshotMoveData: true
                  storageLocation: velero-1
                  ttl: 720h0m0s
                EOF
                while [[ $(oc get -n openshift-adp backup konveyor-backup-$BACKUP_DATE -o go-template='{{ .status.phase }}') != "Completed" ]]; do sleep 5; done
                oc scale -n konveyor-tackle statefulsets --all --replicas=1
                oc scale -n konveyor-tackle deployments --all --replicas=1
          restartPolicy: OnFailure
          serviceAccount: job-runner
```

## Running Restores

Running a restore of the namespace is not much different than a restore for any other application. All we need to do is pick a backup to restore and create the restore resource:

```
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restore
  namespace: openshift-adp
spec:
  backupName: backup-2025-03-12-14-25-24
  includedResources: []
  excludedResources:
  - nodes
  - events
  - events.events.k8s.io
  - backups.velero.io
  - restores.velero.io
  - resticrepositories.velero.io
  restorePVs: true
```
