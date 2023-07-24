#!/bin/bash

set -e
set -x

TACKLE_OPERATOR_INDEX_IMAGE="${TACKLE_OPERATOR_INDEX_IMAGE:-quay.io/konveyor/tackle2-operator-index:latest}"
TACKLE_HUB_IMAGE="${TACKLE_HUB_IMAGE:-quay.io/konveyor/tackle2-hub:latest}"
TACKLE_PATHFINDER_IMAGE="${TACKLE_PATHFINDER_IMAGE:-quay.io/konveyor/tackle-pathfinder:1.3.0-native}"
TACKLE_UI_IMAGE="${TACKLE_UI_IMAGE:-quay.io/konveyor/tackle2-ui:latest}"
TACKLE_UI_INGRESS_CLASS_NAME="${TACKLE_UI_INGRESS_CLASS_NAME:-nginx}"
TACKLE_ADDON_ADMIN_IMAGE="${TACKLE_ADDON_ADMIN_IMAGE:-quay.io/konveyor/tackle2-addon:latest}"
TACKLE_ADDON_ANALYZER_IMAGE="${TACKLE_ADDON_ANALYZER_IMAGE:-quay.io/konveyor/tackle2-addon-analyzer:latest}"
TACKLE_IMAGE_PULL_POLICY="${TACKLE_IMAGE_PULL_POLICY:-Always}"
TACKLE_ANALYZER_CONTAINER_REQUESTS_MEMORY="${TACKLE_ANALYZER_CONTAINER_REQUESTS_MEMORY:-0}"
TACKLE_ANALYZER_CONTAINER_REQUESTS_CPU="${TACKLE_ANALYZER_CONTAINER_REQUESTS_CPU:-0}"

TACKLE_FEATURE_AUTH_REQUIRED="${TACKLE_FEATURE_AUTH_REQUIRED:-false}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Please install kubectl"
  exit 1
fi

# Create namespace
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: konveyor-tackle
EOF

# Create catalogsource
cat << EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: konveyor-tackle
  namespace: konveyor-tackle
spec:
  displayName: Konveyor Operator
  publisher: Konveyor
  sourceType: grpc
  image: ${TACKLE_OPERATOR_INDEX_IMAGE}
EOF

# Create operatorgroup
cat << EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: konveyor-tackle
  namespace: konveyor-tackle
spec:
  targetNamespaces:
    - konveyor-tackle
EOF

# Create, and wait for, subscription
cat << EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: konveyor-operator
  namespace: konveyor-tackle
spec:
  channel: development
  installPlanApproval: Automatic
  name: konveyor-operator
  source: konveyor-tackle
  sourceNamespace: konveyor-tackle
EOF
# If on MacOS, need to install `brew install coreutils` to get `timeout`
timeout 600s bash -c 'until kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io; do sleep 30; done'

# Create, and wait for, tackle
kubectl wait \
  --namespace konveyor-tackle \
  --for=condition=established \
  customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io
cat <<EOF | kubectl apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  feature_auth_required: ${TACKLE_FEATURE_AUTH_REQUIRED}
  hub_image_fqin: ${TACKLE_HUB_IMAGE}
  pathfinder_image_fqin: ${TACKLE_PATHFINDER_IMAGE}
  ui_image_fqin: ${TACKLE_UI_IMAGE}
  ui_ingress_class_name: ${TACKLE_UI_INGRESS_CLASS_NAME}
  admin_fqin: ${TACKLE_ADDON_ADMIN_IMAGE}
  analyzer_fqin: ${TACKLE_ADDON_ANALYZER_IMAGE}
  image_pull_policy: ${TACKLE_IMAGE_PULL_POLICY}
  analyzer_container_requests_memory: ${TACKLE_ANALYZER_CONTAINER_REQUESTS_MEMORY}
  analyzer_container_requests_cpu: ${TACKLE_ANALYZER_CONTAINER_REQUESTS_CPU}
EOF
# Wait for reconcile to finish
kubectl wait \
  --namespace konveyor-tackle \
  --for=condition=Successful \
  --timeout=600s \
  tackles.tackle.konveyor.io/tackle \
|| kubectl get \
  --namespace konveyor-tackle \
  -o yaml
  tackles.tackle.konveyor.io/tackle # Print debug output when waiting failed

# Now wait for all the tackle deployments
kubectl wait \
  --namespace konveyor-tackle \
  --selector="app.kubernetes.io/part-of=tackle" \
  --for=condition=Available \
  --timeout=600s \
  deployments.apps
