# Konveyor Tackle k8s Installation Instructions

## Pre-requisites

- **Kubernetes cluster or Minikube v1.19+**
- **Operator Lifecycle Manager (OLM)**

### Installing OLM support

We strongly suggest OLM support for Tackle deployments, in some production kubernetes clusters OLM might already be present, if not, see the following examples in how to add OLM support to minikube or standard kubernetes clusters below:

#### Minikube:
`$ minikube addons enable olm`

#### Kubernetes:
`$ kubectl apply -f https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart/crds.yaml`

`$ kubectl apply -f https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart/olm.yaml`

For details and official instructions in how to add OLM support to kubernetes and customize your installation see [here](https://github.com/operator-framework/operator-lifecycle-manager/blob/master/doc/install/install.md)

**Note:** Please wait a few minutes for OLM support to become available if this is a new deployment.

### Installing _latest_

Deploy Tackle using manifest:

`$ kubectl apply -f https://raw.githubusercontent.com/konveyor/tackle2-operator/main/tackle-k8s.yaml`

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
