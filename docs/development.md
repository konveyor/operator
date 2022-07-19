# Overview

The following guide attempts to aid developers in working and testing Tackle operator changes using a deployment within a cluster. This method is recommended and the most complete way to test operator changes.

Alternatively, it is possible to test operators locally outside a cluster but is not covered in this guide, if you want to learn more about this see [here](https://sdk.operatorframework.io/docs/building-operators/ansible/tutorial/#1-run-locally-outside-the-cluster).

## Development environment setup

Before you begin, the following tools need to be installed in your dev system:

* [__k8s v1.22+__](https://kubernetes.io/) or [__OpenShift 4.9+__](https://www.openshift.com/)
* [__Operator SDK__](https://sdk.operatorframework.io/docs/installation/)
* [__Operator Lifecycle Manager (OLM) support__](https://olm.operatorframework.io/) (minikube/k8s clusters)
* [__OPM__](https://github.com/operator-framework/operator-registry/)
* __Podman__ and __Docker__

Also, at a very minimum you will need **three Quay repos** to serve and store images related to operator development:

* tackle2-operator, operator images (ansible operator itself)
* tackle2-operator-bundle, operator bundle images (operator versions)
* tackle2-operator-index, index images (index of operator versions used by CatalogSource)

These repos must be **publicly accessible** and you must have enough permissions to push images with your Quay credentials. In most cases, your own organization (Quay username) in Quay is used (i.e quay.io/username/repo-name). This is the recommended setup for development.

## Opdev script

The [opdev](../tools/tackle-opdev.sh) helper script automates the process of building, publishing and installing operator development builds. It simplifies the most common tasks that would be otherwise manually done using operator-sdk and rest of tooling needed to build and publish operators for testing purposes.

Usage:

```
 ./tackle-opdev.sh -h

Valid arguments for tackle-opdev.sh:

	-n : Quay ORG used for Tackle development repos (required)
	-o : Build and push operator image
	-b : Build and push bundle image
	-i : Build and push index image
	-c : Create custom Tackle catalogsource
	-d : Deploy development Tackle for testing

```

The script resides in the tools directory of the operator repo. The only required option is -n , which is your Quay organization that hosts your operator _development_ repos. You must be logged in to your cluster (as admin) and quay account prior attempting to run.

If you want more in-depth details regarding these operator SDK procedures please check the [Operator SDK ansible tutorial](https://sdk.operatorframework.io/docs/building-operators/ansible/tutorial/).

## Development flow

The usual dev order flow for operator is as follows:

* Create and make changes in your operator branch
* Build and push your changes to your Quay org
* Deploy from a development catalogsource and validate changes
* Commit changes and submit PR to tackle2-operator repo

**Note**: Please use forks when submitting your PR, we want to avoid rogue branches in base repo.

## How do I push and test my Tackle operator changes?

|Where is your change?|You changed|To test your changes|
|---|---|---|
|`./roles`| Operator roles content |[Build and push a development operator image](#build-and-push-a-development-operator-container-image) |
|`./bundle`| Operator OLM metadata | [Build and push a development bundle and index image](#build-and-push-a-development-operator-bundle-and-index-image) |
|`both` | Operator OLM metadata and roles content | [Build and push operator including OLM metadata](#build-and-push-all)

## Build and push all

This is recommended as a first time run, as it will populate all dev repos and also will create a custom CatalogSource in your cluster

```
./tackle-opdev.sh -n <your-quay-org> -obic
```

## Build and push a development operator container image

This example only builds and pushes an operator image, if changes were only made to the ansible roles, this is the option that makes the most sense.

```
./tackle-opdev.sh -n <your-quay-org> -o
```

## Build and push a development operator bundle and index image

This is useful when only OLM metadata changes have taken place, bundle and index images are built and also a CatalogSource is created. In addition, the ClusterServiceVersion (CSV) is modified to use the custom operator development image prior building the bundle.

```
./tackle-opdev.sh -n <your-quay-org> -bic
```

## Testing a development operator using a deployment

Before continuing, ensure the existance and health of the CatalogSource:

```
kubectl -n konveyor-tackle get catalogsource
NAME              DISPLAY              TYPE   PUBLISHER   AGE
konveyor-tackle   Tackle Development   grpc   Konveyor    6m22s
```

The index image used by _CatalogSource_ includes the bundle created for this development build.

### Deploy a development operator

The deploy option will create a few resources necessary to install Tackle using OLM such as ensuring an _OperatorGroup_ and _Subscription_ are in place (by default all objects are created in the konveyor-tackle namespace).

```
./tackle-opdev.sh -n <your-quay-org> -d
```

### Check operator health:

```
kubectl -n konveyor-tackle get pods

NAME                                                              READY   STATUS      RESTARTS   AGE
9b6988c5dc0b97094709d01690545526798779eaa2285b4e9f67620573ldd7k   0/1     Completed   0          69s
konveyor-tackle-jw4xr                                             1/1     Running     0          10m
tackle-operator-687cb57d7d-tsb8v                                  1/1     Running     0          56s
```

The operator pod can be inspected further by ensuring the correct image is being pulled and there are other warnings or errors in logs.

### Create a _Tackle_ CR

Create and customize the CR spec as needed, example:

```
$ cat << EOF | kubectl -n konveyor-tackle apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
EOF
```

### Check status of _Tackle_ CR

The operator watches _Tackle_ and manages the status, we can check the health of each reconcile cycle by inspecting the CR:

```
kubectl describe tackle
...
Status:
  Conditions:
    Last Transition Time:  2022-07-19T13:53:54Z
    Message:               
    Reason:                
    Status:                False
    Type:                  Failure
    Ansible Result:
      Changed:             0
      Completion:          2022-07-19T13:56:22.050148
      Failures:            0
      Ok:                  33
      Skipped:             17
    Last Transition Time:  2022-07-19T13:51:44Z
    Message:               Awaiting next reconciliation
    Reason:                Successful
    Status:                True
    Type:                  Running
    Last Transition Time:  2022-07-19T13:56:22Z
    Message:               Last reconciliation succeeded
    Reason:                Successful
    Status:                True
    Type:                  Successful
Events:                    <none>
```

Any operator errors encountered during reconcile will be reported, for further info, the operator pod logs can be inspected.

## Cleanup

Use the tackle [cleanup script](../tools/tackle-cleanup.sh) which is supplied with operator, it will ensure all resources are properly deleted.

Example for k8s clusters:

```
./tackle-cleanup.sh -k
```
