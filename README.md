# Konveyor Tackle Operator

The Konveyor Tackle Operator fully manages the deployment and life cycle of Tackle on OpenShift and Kubernetes.

## Konveyor Tackle Operator Installation

### Installing _latest_

Installing latest requires creating a new catalog source.

1. `oc create -f tackle-operator-catalog.yaml`
1. Visit the OpenShift Web Console.
1. Navigate to _Operators => OperatorHub_.
1. Search for _Tackle_.
1. There should be two _Tackle_ available for installation now.
1. Select the _Tackle_ without the _community_ tag.
1. Proceed to install latest.

## Tackle CR Creation

1. Visit OpenShift Web Console, navigate to _Operators => Installed Operators_.
1. Select _Tackle_.
1. Locate _Tackle_ on the top menu and click on it.
1. Adjust settings if desired and click Create instance.

### Installing _latest_ on Kubernetes (or Minikube)

See [k8s.md](./docs/k8s.md) for details.

## Customize Settings

Custom settings can be applied by editing the `Tackle` CR.

`oc edit tackle -n <tackle-namespace>`

## Tackle Documentation

See the [Konveyor Tackle Documentation](https://tackle-docs.konveyor.io/) for detailed installation instructions as well as how to use Konveyor Tackle.
