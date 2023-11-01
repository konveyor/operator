# Konveyor Operator

[![License](http://img.shields.io/:license-apache-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0.html) [![contributions welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg?style=flat)](https://github.com/konveyor/tackle2-operator/pulls) [![OpenSSF Best Practices](https://bestpractices.coreinfrastructure.org/projects/7355/badge)](https://bestpractices.coreinfrastructure.org/projects/7355)

The Konveyor Operator fully manages the deployment and life cycle of Konveyor on Kubernetes and OpenShift.

## Prerequisites

Please ensure the following requirements are met prior installation.

* [__k8s v1.22+__](https://kubernetes.io/) or [__OpenShift 4.9+__](https://www.openshift.com/)
* [__Persistent Storage__](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
* [__Operator Lifecycle Manager (OLM) support__](https://olm.operatorframework.io/)
* [__Ingress support__](https://kubernetes.io/docs/concepts/services-networking/ingress/)
* [__Network policy support__](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

### Installing OLM support

We strongly suggest OLM support for Tackle deployments, in some production Kubernetes clusters, OLM might already be present. If not, see the following examples on how to add OLM support to Minikube or standard Kubernetes clusters below:

#### Minikube:

`$ minikube addons enable olm`

`$ minikube addons enable ingress`

#### Kubernetes:

`$ kubectl apply -f https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart/crds.yaml`

`$ kubectl apply -f https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart/olm.yaml`

For detailed and official instructions on adding OLM support to Kubernetes and customizing your installation, refer to [here](https://github.com/operator-framework/operator-lifecycle-manager/blob/master/doc/install/install.md).

**Note:** Please wait a few minutes for OLM support to become available if this is a new deployment.

#### Kubernetes Network Policies

Tackle can provide namespace network isolation if a supported CNI, such as [Calico](https://minikube.sigs.k8s.io/docs/handbook/network_policy/#further-reading), is installed.

`$ minikube start --network-plugin=cni --cni=calico`

## Konveyor Operator Installation on k8s

### Installing _released versions_

Released (or public betas) of Konveyor are installable on Kubernetes via [OperatorHub](https://operatorhub.io/operator/konveyor-operator).

### Installing _latest_

Deploy Konveyor using manifest:

`$ kubectl apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/main/tackle-k8s.yaml`

This step will create the konveyor-tackle namespace, catalogsource, and other OLM-related objects.

### Installing _beta_ (or special branches)

If you need to deploy a beta release (or special branch), please replace the *main* branch in the URL with the desired beta branch (i.e v2.0.0-beta.0):

`$ kubectl apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/v2.0.0-beta.0/tackle-k8s.yaml`

**Note:** Upgrades between beta releases are **not guaranteed**. Once installed, we strongly suggest editing your subscription and switching to Manual upgrade mode for beta releases: `$ kubectl edit subscription` -> installPlanApproval: Manual

### Creating a _Tackle_ CR

**Note:** Tackle **requires** a storage class that supports RWX volumes. Please review storage requirements **prior** to creating the Tackle CR, in case you need to adjust settings.

Use the following command to create the CR:

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

Once the CR is created, the operator will deploy the hub, UI and configure the rest of the required components.

### Verify _Tackle_ Deployment

Depending on your hardware, it should take around 1-3 minutes to deploy Tackle, below is a sample output of a successful deployment

```
$ kubectl get pods
NAME                                                           READY   STATUS      RESTARTS   AGE
c4af2f0f9eab63b6ac49c81b0e517eb37c2efe1bb2ede02e8642cd--1-ghq  0/1     Completed   0          134m
konveyor-tackle-rm6jb                                          1/1     Running     0          134m
tackle-hub-6b6ff674dd-c6xbr                                    1/1     Running     0          130m
tackle-keycloak-postgresql-57f5c44bcc-r9w9s                    1/1     Running     0          131m
tackle-keycloak-sso-c65cd79bf-6j4xr                            1/1     Running     0          130m
tackle-operator-6b65fccb7f-q9lpf                               1/1     Running     0          133m
tackle-ui-5f694bddcb-scbh5                                     1/1     Running     0          130m
```
You can access the Konveyor UI in your browser through the `$(minikube ip)` IP.

If you're looking to install Konveyor operator on macOS, follow the guide [here](docs/installation-macos.md).

## Konveyor Operator Installation on OKD/OpenShift

### Installing _released versions_

Released (or public betas) of Konveyor are installable on OpenShift via community operators which appear in [OCP](https://openshift.com/) and [OKD](https://www.okd.io/).

1. Visit the OpenShift Web Console.
2. Navigate to _Operators => OperatorHub_.
3. Search for _Konveyor_.
4. Install the desired _Konveyor_ version.

### Installing _latest_

Installing the latest version is almost identical to installing released versions but requires creating a new catalog source.

1. `oc apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/main/konveyor-operator-catalog.yaml`

2. Visit the OpenShift Web Console.
3. Navigate to _Operators => OperatorHub_.
4. Search for _Konveyor_.
5. There should be two _Konveyor_ available for installation now.
6. Select the _Konveyor_ version **without** the _community_ tag.
7. Proceed to install the latest version using the _development_ channel during the subscription step.

### Tackle CR Creation

1. Visit the OpenShift Web Console, navigate to _Operators => Installed Operators_.
2. Select _Konveyor_.
3. Locate _Konveyor_ in the top menu and click on it.
4. Adjust settings if desired and click "Create instance".

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
cache_data_volume_size | 100Gi | Size requested for Tackle Cache volume
cache_storage_class | N/A | Storage class requested for Tackle Cache volume
hub_bucket_storage_class | N/A | Storage class requested for Tackle Hub Bucket volume

## Tackle CR Customize Settings

Custom settings can be applied by editing the `Tackle` CR.

`oc edit tackle -n <your-tackle-namespace>`

## Konveyor Storage Requirements

Konveyor requires a total of 5 persistent volumes (PVs) used by different components to successfully deploy, 3 RWO volumes and 2 RWX volumes will be requested via PVCs.

Name | Default Size | Access Mode | Description
--- | --- | --- | ---
hub database | 5Gi | RWO | Hub DB
hub bucket | 100Gi | RWX | Hub file storage
keycloak postgresql | 1Gi | RWO | Keycloak backend DB
cache | 100Gi | RWX | cache repository

### Konveyor Storage Custom Settings Example

The example below requests a custom hub bucket volume size and RWX storage class

```
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: <your-konveyor-namespace>
spec:
  hub_bucket_volume_size: "50Gi"
  cache_storage_class: "nfs"
```

## Development

See [development.md](docs/development.md) for details in how to contribute to Tackle operator.

## Konveyor Documentation

See the [Konveyor Documentation](https://konveyor.github.io/konveyor/) for detailed installation instructions as well as how to use Konveyor.

## Code of Conduct
Refer to Konveyor's Code of Conduct [here](https://github.com/konveyor/community/blob/main/CODE_OF_CONDUCT.md).
