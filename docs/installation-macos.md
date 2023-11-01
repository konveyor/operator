# Konveyor local installation guide for MacOS using Minikube & Podman

## Prerequisites:
* [Podman](https://podman.io/getting-started/installation)
* [Minikube](https://minikube.sigs.k8s.io/docs/start/)

## Installation:
1. Initialize `podman machine` using the below config
```
podman machine init --cpus 2 --memory 10240 --disk-size 20
podman machine set --rootful
podman machine start
```
2. Create a Minikube cluster with podman as the driver option
`minikube start --memory=9g --driver podman`
3. Install ingress addon
`minikube addons enable ingress`
4. Install OLM to manage Konveyor operator
`curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.21.2/install.sh | bash -s v0.21.2`
5. Install Konveyor operator
`kubectl create -f https://operatorhub.io/install/konveyor-operator.yaml`
6. Verify if the Konveyor operator pod is running or not
`kubectl get pods -n my-konveyor-operator`
7. Once the operator pod is running, create a Tackle instance using the following 
```
cat << EOF | kubectl apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: my-konveyor-operator
spec:
  feature_auth_required: false
EOF

```

8. Wait until Tackle pods are in running state
```
$ kubectl get pods -n my-konveyor-operator
NAME                                           READY   STATUS      RESTARTS   AGE
tackle-hub-7f7cc9d574-b5kkl                    1/1     Running     0          109m
tackle-operator-56c574d689-jmvs7               1/1     Running     0          111m
tackle-ui-5bdb565bcd-g6gsr                     1/1     Running     0          109m
task-1-x6fmv                                 0/1     Completed   0          4m6s 
```

9. Once they are running, access the Tackle UI,
`kubectl port-forward service/tackle-ui 8080:8080 -n my-konveyor-operator`

*Note: add `--address` param if using aws ec2 instances*
