#!/bin/bash

set -E
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
OPERATOR_BUNDLE_IMAGE="${OPERATOR_BUNDLE_IMAGE:-quay.io/konveyor/tackle2-operator-bundle:release-0.8}"
HUB_IMAGE="${HUB_IMAGE:-quay.io/konveyor/tackle2-hub:release-0.8}"
UI_IMAGE="${UI_IMAGE:-quay.io/konveyor/tackle2-ui:release-0.8}"
UI_INGRESS_CLASS_NAME="${UI_INGRESS_CLASS_NAME:-nginx}"
ADDON_ANALYZER_IMAGE="${ADDON_ANALYZER_IMAGE:-quay.io/konveyor/tackle2-addon-analyzer:release-0.8}"
JAVA_PROVIDER_IMAGE="${JAVA_PROVIDER_IMAGE:-quay.io/konveyor/java-external-provider:release-0.8}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Always}"
ANALYZER_CONTAINER_REQUESTS_MEMORY="${ANALYZER_CONTAINER_REQUESTS_MEMORY:-0}"
ANALYZER_CONTAINER_REQUESTS_CPU="${ANALYZER_CONTAINER_REQUESTS_CPU:-0}"
FEATURE_AUTH_REQUIRED="${FEATURE_AUTH_REQUIRED:-false}"
TIMEOUT="${TIMEOUT:-15m}"
OLM_VERSION="${OLM_VERSION:-0.28.0}"
DISABLE_MAVEN_SEARCH="${DISABLE_MAVEN_SEARCH:-false}"

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

debug() {
  set +e
  echo "Install Konveyor FAILED!!!"
  echo "What follows is some info that may be useful in debugging the failure"

  if [ "${CI}" == "true" ]; then
    debug_output="/tmp/konveyor-debug"
    mkdir -p "${debug_output}"
    namespace="${debug_output}/namespace.yaml"
    all="${debug_output}/all_resources.yaml"
    operator="${debug_output}/operator_resources.yaml"
    tackle="${debug_output}/tackle.yaml"
    pods="${debug_output}/pod_descriptions.yaml"

    kubectl get namespace "${NAMESPACE}" -o yaml | tee "${namespace}"
    kubectl get --namespace "${NAMESPACE}" all | tee "${all}"
    kubectl get --namespace "${NAMESPACE}" -o yaml \
      subscriptions.operators.coreos.com,catalogsources.operators.coreos.com,installplans.operators.coreos.com,clusterserviceversions.operators.coreos.com | tee "${operator}"
    kubectl get --namespace "${NAMESPACE}" -o yaml tackles.tackle.konveyor.io/tackle | tee "${tackle}"

    for pod in $(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
      kubectl --namespace "${NAMESPACE}" describe pod "${pod}" | tee -a "${pods}"
      kubectl --namespace "${NAMESPACE}" logs "${pod}" | tee "${debug_output}/${pod}.log"
    done
  else
    kubectl get namespace "${NAMESPACE}" -o yaml
    kubectl get --namespace "${NAMESPACE}" all
    kubectl get --namespace "${NAMESPACE}" -o yaml \
      subscriptions.operators.coreos.com,catalogsources.operators.coreos.com,installplans.operators.coreos.com,clusterserviceversions.operators.coreos.com
    kubectl get --namespace "${NAMESPACE}" -o yaml tackles.tackle.konveyor.io/tackle

    for pod in $(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
      kubectl --namespace "${NAMESPACE}" describe pod "${pod}"
    done
  fi

  exit 1
}
trap 'debug' ERR

install_operator() {
  kubectl auth can-i create namespace --all-namespaces
  kubectl create namespace ${NAMESPACE} || true
  operator-sdk run bundle "${OPERATOR_BUNDLE_IMAGE}" --namespace "${NAMESPACE}" --timeout "${TIMEOUT}"

  # If on MacOS, need to install `brew install coreutils` to get `timeout`
  timeout 600s bash -c 'until kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io; do sleep 30; done' \
  || kubectl get subscription --namespace ${NAMESPACE} -o yaml konveyor-operator # Print subscription details when timed out
}

kubectl get customresourcedefinitions.apiextensions.k8s.io clusterserviceversions.operators.coreos.com || operator-sdk olm install --version ${OLM_VERSION}
olm_namespace=$(kubectl get clusterserviceversions.operators.coreos.com --all-namespaces | grep packageserver | awk '{print $1}')
kubectl rollout status -w deployment/olm-operator --namespace="${olm_namespace}"
kubectl rollout status -w deployment/catalog-operator --namespace="${olm_namespace}"
kubectl wait --namespace "${olm_namespace}" --for='jsonpath={.status.phase}'=Succeeded clusterserviceversions.operators.coreos.com packageserver
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
  provider_java_image_fqin: ${JAVA_PROVIDER_IMAGE}
  analyzer_container_requests_cpu: ${ANALYZER_CONTAINER_REQUESTS_CPU}
  disable_maven_search: ${DISABLE_MAVEN_SEARCH}
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
