# Konveyor Tackle Operator

The Konveyor Tackle Operator fully manages the deployment and life cycle of Tackle on OpenShift and Kubernetes.

## Prerequisites

Please ensure the following requirements are met prior installation.

* [__OpenShift 4.7+__](https://www.openshift.com/) or [__k8s v1.20+__](https://kubernetes.io/)
* [__Persistent Storage__](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)

## Konveyor Tackle Operator Installation

### Installing _latest_ on OpenShift

Installing latest requires creating a new catalog source.

1. `oc create -f tackle-operator-catalog.yaml`
1. Visit the OpenShift Web Console.
1. Navigate to _Operators => OperatorHub_.
1. Search for _Tackle_.
1. There should be two _Tackle_ available for installation now.
1. Select the _Tackle_ **without** the _community_ tag.
1. Proceed to install latest.

### Installing _latest_ on Kubernetes (or Minikube)

See [k8s.md](./docs/k8s.md) for details.

## Tackle CR Creation on OpenShift

1. Visit OpenShift Web Console, navigate to _Operators => Installed Operators_.
1. Select _Tackle_.
1. Locate _Tackle_ on the top menu and click on it.
1. Adjust settings if desired and click Create instance.

**Note:** Please review storage requirements **prior** creating the Tackle CR in case you need to adjust settings.

## Tackle CR Settings

If operator defaults need to be altered, the Tackle CR spec can be customized to meet desired needs, see the table below for some of the most significant settings:

Name | Default | Description
--- | --- | ---
hub_database_volume_size | 5Gi | Size requested for Hub database volume
hub_bucket_volume_size | 100gi | Size requested for Hub bucket volume
keycloak_database_data_volume_size | 1Gi | Size requested for Keycloak DB volume
pathfinder_database_data_volume_size | 1Gi | Size requested for Pathfinder DB volume
windup_data_volume_size | 100Gi | Size requested for Windup maven m2 repository volume
tackle_rwx_storage_class | N/A | Storage class requested for Tackle RWX volumes
tackle_rwo_storage_class | N/A | Storage class requested for Tackle RWO volumes

## Tackle CR Customize Settings

Custom settings can be applied by editing the `Tackle` CR.

`oc edit tackle -n <tackle-namespace>`

## Tackle Storage Requirements

Tackle requires a total of 5 persistent volumes (PVs) used by different components to successfully deploy, 3 RWO volumes and 2 RWX volumes will be requested via PVCs.

Name | Default Size | Access Mode | Description
--- | --- | --- | ---
hub database | 5Gi | RWO | Hub DB
hub bucket | 100Gi | RWX | Hub file storage
keycloak postgresql | 1Gi | RWO | Keycloak backend DB
pathfinder postgresql | 1Gi | RWO | Pathfinder backend DB
windup | 100Gi | RWX | Windup maven m2 repository

### Tackle Storage Custom Settings Example

The example below requests a custom hub bucket volume size and also a classless RWX storage class

```
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  hub_bucket_volume_size: "50Gi"
  tackle_rwx_storage_class: "nfs"
```

## Tackle Documentation

See the [Konveyor Tackle Documentation](https://tackle-docs.konveyor.io/) for detailed installation instructions as well as how to use Konveyor Tackle.
