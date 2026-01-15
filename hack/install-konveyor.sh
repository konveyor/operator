#!/bin/bash

set -E
set -e
set -x
set -o pipefail

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
OPERATOR_BUNDLE_IMAGE="${OPERATOR_BUNDLE_IMAGE:-quay.io/konveyor/tackle2-operator-bundle:latest}"
TACKLE_CR="${TACKLE_CR:-}"
TIMEOUT="${TIMEOUT:-15m}"
OLM_VERSION="${OLM_VERSION:-0.28.0}"
DISABLE_MAVEN_SEARCH="${DISABLE_MAVEN_SEARCH:-false}"
FEATURE_AUTH_REQUIRED="${FEATURE_AUTH_REQUIRED:-false}"
KAI_SOLUTION_SERVER_ENABLED="${KAI_SOLUTION_SERVER_ENABLED:-}"
KAI_LLM_MODEL="${KAI_LLM_MODEL:-}"
KAI_LLM_PROVIDER="${KAI_LLM_PROVIDER:-}"
KAI_LLM_BASEURL="${KAI_LLM_BASEURL:-}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Please install kubectl. See https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi

if ! command -v operator-sdk >/dev/null 2>&1; then
  echo "Please install operator-sdk. See https://sdk.operatorframework.io/docs/installation/"
  exit 1
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

run_bundle() {
  kubectl auth can-i create namespace --all-namespaces
  kubectl create namespace "${NAMESPACE}" || true
  operator-sdk run bundle "${OPERATOR_BUNDLE_IMAGE}" --namespace "${NAMESPACE}" --timeout "${TIMEOUT}"

  # If on MacOS, need to install `brew install coreutils` to get `timeout`
  timeout 600s bash -c 'until kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io; do sleep 30; done'
  kubectl get clusterserviceversions.operators.coreos.com -n "${NAMESPACE}" -o yaml
}

install_tackle() {
  echo "Waiting for the Tackle CRD to become available"
  kubectl wait --namespace "${NAMESPACE}" --for=condition=established customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io

  echo "Waiting for the Tackle Operator to exist"
  timeout 2m bash -c "until kubectl --namespace ${NAMESPACE} get deployment/tackle-operator; do sleep 10; done"

  echo "Waiting for the Tackle Operator to become available"
  kubectl rollout status --namespace "${NAMESPACE}" -w deployment/tackle-operator --timeout=600s

  if [ -n "${TACKLE_CR}" ]; then
    echo "${TACKLE_CR}" | kubectl apply --namespace "${NAMESPACE}" -f -
  else
    TACKLE_CR=$(cat <<EOF
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
spec:
  disable_maven_search: ${DISABLE_MAVEN_SEARCH}
  feature_auth_required: ${FEATURE_AUTH_REQUIRED}
${KAI_SOLUTION_SERVER_ENABLED:+  kai_solution_server_enabled: ${KAI_SOLUTION_SERVER_ENABLED}}
${KAI_LLM_MODEL:+  kai_llm_model: ${KAI_LLM_MODEL}}
${KAI_LLM_PROVIDER:+  kai_llm_provider: ${KAI_LLM_PROVIDER}}
${KAI_LLM_BASEURL:+  kai_llm_baseurl: ${KAI_LLM_BASEURL}}
EOF
    )
    echo "${TACKLE_CR}" | kubectl apply --namespace "${NAMESPACE}" -f -
  fi

  # Want to see in github logs what we just created
  kubectl get --namespace "${NAMESPACE}" -o yaml tackles.tackle.konveyor.io/tackle

  # Wait for reconcile to finish
  kubectl wait \
    --namespace "${NAMESPACE}" \
    --for=condition=Successful \
    --timeout=600s \
    tackles.tackle.konveyor.io/tackle

  # Now wait for all the tackle deployments
  kubectl wait \
    --namespace "${NAMESPACE}" \
    --selector="app.kubernetes.io/part-of=tackle" \
    --for=condition=Available \
    --timeout=600s \
    deployments.apps

  kubectl get deployments.apps -n "${NAMESPACE}" -o yaml
}

install_olm() {
  local max_attempts=3
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt of $max_attempts: Installing OLM version ${OLM_VERSION}..."
    if operator-sdk olm install --version ${OLM_VERSION}; then
      echo "OLM installation successful"
      return 0
    fi
    
    if [ $attempt -lt $max_attempts ]; then
      echo "OLM installation failed (possibly due to network issues), retrying in 10 seconds..."
      sleep 10
    fi
    attempt=$((attempt + 1))
  done
  
  echo "Failed to install OLM after $max_attempts attempts"
  return 1
}

kubectl get customresourcedefinitions.apiextensions.k8s.io clusterserviceversions.operators.coreos.com || install_olm
olm_namespace=$(kubectl get clusterserviceversions.operators.coreos.com --all-namespaces | grep packageserver | awk '{print $1}')
kubectl rollout status -w deployment/olm-operator --namespace="${olm_namespace}"
kubectl rollout status -w deployment/catalog-operator --namespace="${olm_namespace}"
kubectl wait --namespace "${olm_namespace}" --for='jsonpath={.status.phase}'=Succeeded clusterserviceversions.operators.coreos.com packageserver
kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io || run_bundle
install_tackle
