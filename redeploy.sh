#!/bin/bash
set -e

echo "Step 3: Building and pushing bundle..."
podman build -f bundle.Dockerfile -t quay.io/jortel/tackle2-operator-bundle:latest . && \
podman push quay.io/jortel/tackle2-operator-bundle:latest

echo "Step 4: Building and pushing index..."
opm index add --bundles quay.io/jortel/tackle2-operator-bundle:latest --tag quay.io/jortel/tackle2-operator-index:latest && \
podman push quay.io/jortel/tackle2-operator-index:latest

echo "Step 5: Deleting existing operator installation..."
oc delete subscription konveyor-operator -n konveyor-tackle
oc delete csv konveyor-operator.v99.0.0 -n konveyor-tackle
oc delete crd addons.tackle.konveyor.io extensions.tackle.konveyor.io schemas.tackle.konveyor.io tackles.tackle.konveyor.io tasks.tackle.konveyor.io identityproviders.tackle.konveyor.io idpclients.tackle.konveyor.io ldapproviders.tackle.konveyor.io 2>/dev/null || true

echo "Step 6: Restarting catalog pod..."
oc delete pod -n konveyor-tackle -l olm.catalogSource=konveyor

echo "Waiting for catalog to restart..."
sleep 10

echo "Step 7: Applying install.yaml..."
oc apply -f hack/install.yaml

echo "Waiting for CSV to install..."
sleep 15

echo "Step 8: Updating CSV to use oidc image..."
oc patch csv konveyor-operator.v99.0.0 -n konveyor-tackle --type=json \
  -p='[{"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/image", "value": "quay.io/jortel/tackle2-operator:oidc"}]'

echo "Waiting for operator to be ready..."
sleep 10

echo "Step 9: Creating Tackle CR..."
oc delete tackle tackle -n konveyor-tackle 2>/dev/null || true
oc create -f ~/openshift/tackle/main.yaml

echo "Done! Checking status..."
oc get csv -n konveyor-tackle
oc get crd | grep tackle
oc get tackle -n konveyor-tackle
