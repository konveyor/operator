#!/bin/bash

set -e
set -x

# Figure out where we are being run from.
# This relies on script being run from:
#  - ${PROJECT_ROOT}/hack/install-tackle.sh
#  - ${PROJECT_ROOT}/bin/install-tackle.sh
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__root="$(cd "$(dirname "${__dir}")" && pwd)"
__repo="$(basename "${__root}")"
__bin_dir="${__root}/bin"
__os="$(uname -s | tr '[:upper:]' '[:lower:]')"
__arch="$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"

# Update PATH for execution of this script
export PATH="${__bin_dir}:${PATH}"

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
OPERATOR_BUNDLE_IMAGE="${OPERATOR_BUNDLE_IMAGE:-quay.io/konveyor/tackle2-operator-bundle:latest}"
HUB_IMAGE="${HUB_IMAGE:-quay.io/konveyor/tackle2-hub:latest}"
UI_IMAGE="${UI_IMAGE:-quay.io/konveyor/tackle2-ui:latest}"
UI_INGRESS_CLASS_NAME="${UI_INGRESS_CLASS_NAME:-nginx}"
ADDON_ANALYZER_IMAGE="${ADDON_ANALYZER_IMAGE:-quay.io/konveyor/tackle2-addon-analyzer:latest}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Always}"
ANALYZER_CONTAINER_REQUESTS_MEMORY="${ANALYZER_CONTAINER_REQUESTS_MEMORY:-0}"
ANALYZER_CONTAINER_REQUESTS_CPU="${ANALYZER_CONTAINER_REQUESTS_CPU:-0}"
FEATURE_AUTH_REQUIRED="${FEATURE_AUTH_REQUIRED:-false}"

if ! command -v kubectl >/dev/null 2>&1; then
  kubectl_bin="${__bin_dir}/kubectl"
  mkdir -p "${__bin_dir}"
  curl -Lo "${kubectl_bin}" "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${__os}/${__arch}/kubectl"
  chmod +x "${kubectl_bin}"
fi

if ! command -v operator-sdk1 >/dev/null 2>&1; then
  operator_sdk_bin="${__bin_dir}/operator-sdk"
  mkdir -p "${__bin_dir}"

  version=$(curl --silent "https://api.github.com/repos/operator-framework/operator-sdk/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  curl -Lo "${operator_sdk_bin}" "https://github.com/operator-framework/operator-sdk/releases/download/${version}/operator-sdk_${__os}_${__arch}"
  chmod +x "${operator_sdk_bin}"
fi

install_operator() {
  kubectl auth can-i create namespace --all-namespaces
  kubectl create namespace ${NAMESPACE} || true
  operator-sdk run bundle ${OPERATOR_BUNDLE_IMAGE} --namespace ${NAMESPACE}

  # If on MacOS, need to install `brew install coreutils` to get `timeout`
  timeout 600s bash -c 'until kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io; do sleep 30; done' \
  || kubectl get subscription --namespace ${NAMESPACE} -o yaml konveyor-operator # Print subscription details when timed out
}

kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io || install_operator


# Create, and wait for, tackle
kubectl wait \
  --namespace ${NAMESPACE} \
  --for=condition=established \
  customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io
cat <<EOF | kubectl apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: ${NAMESPACE}
spec:
  feature_auth_required: ${FEATURE_AUTH_REQUIRED}
  hub_image_fqin: ${HUB_IMAGE}
  ui_image_fqin: ${UI_IMAGE}
  ui_ingress_class_name: ${UI_INGRESS_CLASS_NAME}
  analyzer_fqin: ${ADDON_ANALYZER_IMAGE}
  image_pull_policy: ${IMAGE_PULL_POLICY}
  analyzer_container_requests_memory: ${ANALYZER_CONTAINER_REQUESTS_MEMORY}
  analyzer_container_requests_cpu: ${ANALYZER_CONTAINER_REQUESTS_CPU}
EOF
# Wait for reconcile to finish
kubectl wait \
  --namespace ${NAMESPACE} \
  --for=condition=Successful \
  --timeout=600s \
  tackles.tackle.konveyor.io/tackle \
|| kubectl get \
  --namespace ${NAMESPACE} \
  -o yaml \
  tackles.tackle.konveyor.io/tackle # Print tackle debug when timed out

# Now wait for all the tackle deployments
kubectl wait \
  --namespace ${NAMESPACE} \
  --selector="app.kubernetes.io/part-of=tackle" \
  --for=condition=Available \
  --timeout=600s \
  deployments.apps \
|| kubectl get \
  --namespace ${NAMESPACE} \
  --selector="app.kubernetes.io/part-of=tackle" \
  --field-selector=status.phase!=Running  \
  -o yaml \
  pods # Print not running tackle pods when timed out
