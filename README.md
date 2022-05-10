# Tackle Operator

[![Operator Repository on Quay](https://quay.io/repository/konveyor/tackle2-operator/status "Operator Repository on Quay")](https://quay.io/repository/konveyor/tackle2-operator) [![License](http://img.shields.io/:license-apache-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0.html) [![contributions welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg?style=flat)](https://github.com/konveyor/tackle2-operator/pulls)

The Tackle Operator fully manages the deployment and life cycle of Tackle on Kubernetes and OpenShift.

## Prerequisites

Please ensure the following requirements are met prior installation.

* [__k8s v1.20+__](https://kubernetes.io/) or [__OpenShift 4.7+__](https://www.openshift.com/)
* [__Persistent Storage__](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
* [__Operator Lifecycle Manager (OLM) support__](https://olm.operatorframework.io/)
* [__Ingress support__](https://kubernetes.io/docs/concepts/services-networking/ingress/)

## Tackle Operator Installation

### Installing OLM support

We strongly suggest OLM support for Tackle deployments, in some production kubernetes clusters OLM might already be present, if not, see the following examples in how to add OLM support to minikube or standard kubernetes clusters below:

#### Minikube:

`$ minikube addons enable olm`

`$ minikube addons enable ingress`

#### Kubernetes:

`$ kubectl apply -f https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart/crds.yaml`

`$ kubectl apply -f https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart/olm.yaml`

For details and official instructions in how to add OLM support to kubernetes and customize your installation see [here](https://github.com/operator-framework/operator-lifecycle-manager/blob/master/doc/install/install.md)

**Note:** Please wait a few minutes for OLM support to become available if this is a new deployment.

### Installing _latest_ on k8s (or minikube)

Deploy Tackle using manifest:

`$ kubectl apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/main/tackle-k8s.yaml`

This step will create the konveyor-tackle namespace, catalogsource and other OLM related objects.

### Creating a _Tackle_ CR
```
$ cat << EOF | kubectl apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
EOF
```

**Note:** Please review storage requirements **prior** creating the Tackle CR in case you need to adjust settings.

### Verify _Tackle_ Deployment

Depending on your hardware it should take around 1-3 minutes to deploy Tackle, below is a sample output of a successful deployment

```
$ kubectl get pods
NAME                                                           READY   STATUS      RESTARTS   AGE
c4af2f0f9eab63b6ac49c81b0e517eb37c2efe1bb2ede02e8642cd--1-ghq  0/1     Completed   0          134m
konveyor-tackle-rm6jb                                          1/1     Running     0          134m
tackle-hub-6b6ff674dd-c6xbr                                    1/1     Running     0          130m
tackle-keycloak-postgresql-57f5c44bcc-r9w9s                    1/1     Running     0          131m
tackle-keycloak-sso-c65cd79bf-6j4xr                            1/1     Running     0          130m
tackle-operator-6b65fccb7f-q9lpf                               1/1     Running     0          133m
tackle-pathfinder-6c58447d8f-rd6rr                             1/1     Running     0          130m
tackle-pathfinder-postgresql-5fff469bcc-bc5z2                  1/1     Running     0          130m
tackle-ui-5f694bddcb-scbh5                                     1/1     Running     0          130m
```

### Installing _latest_ on OpenShift

Installing latest requires creating a new catalog source.

1. `oc create -f tackle-operator-catalog.yaml`
1. Visit the OpenShift Web Console.
1. Navigate to _Operators => OperatorHub_.
1. Search for _Tackle_.
1. There should be two _Tackle_ available for installation now.
1. Select the _Tackle_ **without** the _community_ tag.
1. Proceed to install latest.

## Tackle CR Creation on OpenShift

1. Visit OpenShift Web Console, navigate to _Operators => Installed Operators_.
1. Select _Tackle_.
1. Locate _Tackle_ on the top menu and click on it.
1. Adjust settings if desired and click Create instance.

## Tackle CR Settings

If operator defaults need to be altered, the Tackle CR spec can be customized to meet desired needs, see the table below for some of the most significant settings:

Name | Default | Description
--- | --- | ---
feature_auth_required | true | Enable keycloak auth or false (single user/noauth)
hub_database_volume_size | 5Gi | Size requested for Hub database volume
hub_bucket_volume_size | 100gi | Size requested for Hub bucket volume
keycloak_database_data_volume_size | 1Gi | Size requested for Keycloak DB volume
pathfinder_database_data_volume_size | 1Gi | Size requested for Pathfinder DB volume
maven_data_volume_size | 100Gi | Size requested for maven m2 repository volume
rwx_storage_class | N/A | Storage class requested for Tackle RWX volumes
rwo_storage_class | N/A | Storage class requested for Tackle RWO volumes

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
maven | 100Gi | RWX | maven m2 repository

### Tackle Storage Custom Settings Example

The example below requests a custom hub bucket volume size and RWX storage class

```
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  hub_bucket_volume_size: "50Gi"
  rwx_storage_class: "nfs"
```

## Tackle Documentation

See the [Konveyor Tackle Documentation](https://tackle-docs.konveyor.io/) for detailed installation instructions as well as how to use Tackle.
