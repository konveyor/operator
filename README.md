# Tackle Operator

[![Operator Repository on Quay](https://quay.io/repository/konveyor/tackle2-operator/status "Operator Repository on Quay")](https://quay.io/repository/konveyor/tackle2-operator) [![License](http://img.shields.io/:license-apache-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0.html) [![contributions welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg?style=flat)](https://github.com/konveyor/tackle2-operator/pulls)

The Tackle Operator fully manages the deployment and life cycle of Tackle on Kubernetes and OpenShift.

## Prerequisites

Please ensure the following requirements are met prior installation.

* [__k8s v1.22+__](https://kubernetes.io/) or [__OpenShift 4.9+__](https://www.openshift.com/)
* [__Persistent Storage__](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
* [__Operator Lifecycle Manager (OLM) support__](https://olm.operatorframework.io/)
* [__Ingress support__](https://kubernetes.io/docs/concepts/services-networking/ingress/)
* [__Network policy support__](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

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

#### Kubernetes Network Policies

Tackle can provide namespace network isolation if a supported CNI, such as [Calico](https://minikube.sigs.k8s.io/docs/handbook/network_policy/#further-reading), is installed.

`$ minikube start --network-plugin=cni --cni=calico`

## Tackle Operator Installation on k8s

### Installing _released versions_

Released (or public betas) of Tackle are installable on Kubernetes via [OperatorHub](https://operatorhub.io/operator/tackle-operator).

### Installing _latest_

Deploy Tackle using manifest:

`$ kubectl apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/main/tackle-k8s.yaml`

This step will create the konveyor-tackle namespace, catalogsource and other OLM related objects.

### Installing _beta_ (or special branches)

If you need to deploy a beta release (or special branch) please replace the *main* branch in URL with the desired beta branch (i.e v2.0.0-beta.0):

`$ kubectl apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/v2.0.0-beta.0/tackle-k8s.yaml`

**Note:** Upgrades between beta releases are **not guaranteed** , once installed, we strongly suggest to edit your subscription and switch to Manual upgrade mode for beta releases: `$ kubectl edit subscription` -> installPlanApproval: Manual

### Creating a _Tackle_ CR

**Note:** Tackle **requires** a storage class that supports RWX volumes, please review storage requirements **prior** creating the Tackle CR in case you need to adjust settings.

```
$ cat << EOF | kubectl apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: <your-tackle-namespace>
spec:
EOF
```

Once the CR is created, the operator will deploy the hub, UI and configure the rest of required components.

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

## Tackle Operator Installation on OKD/OpenShift

### Installing _released versions_

Released (or public betas) of Tackle are installable on OpenShift via community operators which appear in [OCP](https://openshift.com/) and [OKD](https://www.okd.io/).

1. Visit the OpenShift Web Console.
1. Navigate to _Operators => OperatorHub_.
1. Search for _Tackle_.
1. Install the desired _Tackle_ version.

### Installing _latest_

Installing latest is almost an identical procedure to released versions but requires creating a new catalog source.

1. `oc apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/main/tackle-operator-catalog.yaml`
1. Visit the OpenShift Web Console.
1. Navigate to _Operators => OperatorHub_.
1. Search for _Tackle_.
1. There should be two _Tackle_ available for installation now.
1. Select the _Tackle_ **without** the _community_ tag.
1. Proceed to install latest using the _development_ channel in the subscription step.

### Tackle CR Creation

1. Visit OpenShift Web Console, navigate to _Operators => Installed Operators_.
1. Select _Tackle_.
1. Locate _Tackle_ on the top menu and click on it.
1. Adjust settings if desired and click Create instance.

## Tackle CR Settings

If operator defaults need to be altered, the Tackle CR spec can be customized to meet desired needs, see the table below for some of the most significant settings:

Name | Default | Description
--- | --- | ---
feature_auth_required | true | Enable keycloak auth or false (single user/noauth)
feature_isolate_namespace | true | Enable namespace isolation via network policies
rwx_supported: | true | Whether or not RWX volumes are supported in the cluster
hub_database_volume_size | 5Gi | Size requested for Hub database volume
hub_bucket_volume_size | 100gi | Size requested for Hub bucket volume
keycloak_database_data_volume_size | 1Gi | Size requested for Keycloak DB volume
pathfinder_database_data_volume_size | 1Gi | Size requested for Pathfinder DB volume
cache_data_volume_size | 100Gi | Size requested for Tackle Cache volume
cache_storage_class | N/A | Storage class requested for Tackle Cache volume
hub_bucket_storage_class | N/A | Storage class requested for Tackle Hub Bucket volume

## Tackle CR Customize Settings

Custom settings can be applied by editing the `Tackle` CR.

`oc edit tackle -n <your-tackle-namespace>`

## Tackle Storage Requirements

Tackle requires a total of 5 persistent volumes (PVs) used by different components to successfully deploy, 3 RWO volumes and 2 RWX volumes will be requested via PVCs.

Name | Default Size | Access Mode | Description
--- | --- | --- | ---
hub database | 5Gi | RWO | Hub DB
hub bucket | 100Gi | RWX | Hub file storage
keycloak postgresql | 1Gi | RWO | Keycloak backend DB
pathfinder postgresql | 1Gi | RWO | Pathfinder backend DB
cache | 100Gi | RWX | cache repository

### Tackle Storage Custom Settings Example

The example below requests a custom hub bucket volume size and RWX storage class

```
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: <your-tackle-namespace>
spec:
  hub_bucket_volume_size: "50Gi"
  cache_storage_class: "nfs"
```

## Development

See [development.md](docs/development.md) for details in how to contribute to Tackle operator.

## Tackle Documentation

See the [Konveyor Tackle Documentation](https://tackle-docs.konveyor.io/) for detailed installation instructions as well as how to use Tackle.

## Code of Conduct
Refer to Konveyor's Code of Conduct [here](https://github.com/konveyor/community/blob/main/CODE_OF_CONDUCT.md).
