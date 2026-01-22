#!/bin/bash

set -E
set -e
set -o pipefail

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
OPERATOR_BUNDLE_IMAGE="${OPERATOR_BUNDLE_IMAGE:-quay.io/konveyor/tackle2-operator-bundle:latest}"
TACKLE_CR="${TACKLE_CR:-}"
TIMEOUT="${TIMEOUT:-10m}"  # Reduced from 15m since typical install is <4min
OLM_VERSION="${OLM_VERSION:-0.28.0}"
DISABLE_MAVEN_SEARCH="${DISABLE_MAVEN_SEARCH:-false}"
FEATURE_AUTH_REQUIRED="${FEATURE_AUTH_REQUIRED:-false}"
KAI_SOLUTION_SERVER_ENABLED="${KAI_SOLUTION_SERVER_ENABLED:-}"
KAI_LLM_MODEL="${KAI_LLM_MODEL:-}"
KAI_LLM_PROVIDER="${KAI_LLM_PROVIDER:-}"
KAI_LLM_BASEURL="${KAI_LLM_BASEURL:-}"

# Global timeout configuration - entire script must complete within this time
GLOBAL_TIMEOUT_SECONDS="${GLOBAL_TIMEOUT_SECONDS:-600}"  # 10 minutes default
SCRIPT_START_TIME=$(date +%s)

# Configuration for wait behavior
DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-600}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Please install kubectl. See https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi

if ! command -v operator-sdk >/dev/null 2>&1; then
  echo "Please install operator-sdk. See https://sdk.operatorframework.io/docs/installation/"
  exit 1
fi

# Function to calculate remaining time before global timeout
get_remaining_time() {
  local current_time=$(date +%s)
  local elapsed=$((current_time - SCRIPT_START_TIME))
  local remaining=$((GLOBAL_TIMEOUT_SECONDS - elapsed))
  
  if [ $remaining -le 0 ]; then
    echo "0"
  else
    echo "$remaining"
  fi
}

# Function to wait for multiple background processes and check all exit codes
wait_for_all() {
  local failed=false
  
  for pid in "$@"; do
    if ! wait "$pid"; then
      failed=true
    fi
  done
  
  if [ "$failed" = true ]; then
    return 1
  fi
  return 0
}

# Enhanced debug function with structured output
debug() {
  set +e
  echo ""
  echo "============================================="
  echo "KONVEYOR INSTALLATION FAILED"
  echo "============================================="
  echo "Collecting debug information..."
  echo ""

  if [ "${CI}" == "true" ]; then
    debug_output="/tmp/konveyor-debug"
    mkdir -p "${debug_output}"
    
    echo "=== CLUSTER STATE ==="
    kubectl cluster-info > "${debug_output}/cluster-info.txt" 2>&1
    
    echo ""
    echo "=== NAMESPACE STATE ==="
    kubectl get namespace "${NAMESPACE}" -o yaml > "${debug_output}/namespace.yaml" 2>&1
    
    echo ""
    echo "=== RESOURCES OVERVIEW ==="
    kubectl get --namespace "${NAMESPACE}" all > "${debug_output}/all_resources.txt" 2>&1
    
    echo ""
    echo "=== OPERATOR RESOURCES ==="
    kubectl get --namespace "${NAMESPACE}" -o yaml \
      subscriptions.operators.coreos.com,catalogsources.operators.coreos.com,installplans.operators.coreos.com,clusterserviceversions.operators.coreos.com \
      > "${debug_output}/operator_resources.yaml" 2>&1
    
    echo ""
    echo "=== TACKLE CUSTOM RESOURCE ==="
    kubectl get --namespace "${NAMESPACE}" -o yaml tackles.tackle.konveyor.io/tackle > "${debug_output}/tackle.yaml" 2>&1
    
    echo ""
    echo "=== POD DETAILS ==="
    local pods_output="${debug_output}/pod_details.txt"
    for pod in $(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
      echo "--- Pod: $pod ---" >> "${pods_output}"
      kubectl --namespace "${NAMESPACE}" describe pod "${pod}" >> "${pods_output}" 2>&1
      
      echo "--- Logs for $pod ---" > "${debug_output}/${pod}.log"
      kubectl --namespace "${NAMESPACE}" logs "${pod}" --tail=100 >> "${debug_output}/${pod}.log" 2>&1
    done
    
    echo ""
    echo "=== EVENTS ==="
    kubectl get events --namespace="${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20 > "${debug_output}/events.txt" 2>&1
    
    echo ""
    echo "Debug files saved to: ${debug_output}/"
    ls -la "${debug_output}/"
  else
    echo "=== NAMESPACE STATE ==="
    kubectl get namespace "${NAMESPACE}" -o yaml
    
    echo ""
    echo "=== RESOURCES OVERVIEW ==="
    kubectl get --namespace "${NAMESPACE}" all
    
    echo ""
    echo "=== OPERATOR RESOURCES ==="
    kubectl get --namespace "${NAMESPACE}" -o yaml \
      subscriptions.operators.coreos.com,catalogsources.operators.coreos.com,installplans.operators.coreos.com,clusterserviceversions.operators.coreos.com
    
    echo ""
    echo "=== TACKLE CUSTOM RESOURCE ==="
    kubectl get --namespace "${NAMESPACE}" -o yaml tackles.tackle.konveyor.io/tackle
    
    echo ""
    echo "=== POD DETAILS ==="
    for pod in $(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
      echo "--- Pod: $pod ---"
      kubectl --namespace "${NAMESPACE}" describe pod "${pod}"
      echo ""
    done
    
    echo ""
    echo "=== RECENT EVENTS ==="
    kubectl get events --namespace="${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
  fi

  echo ""
  echo "============================================="
  echo "DEBUG COLLECTION COMPLETE"
  echo "============================================="
  exit 1
}
trap 'debug' ERR

# Function to deploy bundle - waits for OLM operators as precondition
start_bundle() {
  echo "=== Starting Bundle Deployment ==="
  
  # Precondition: Wait for OLM operators to be ready
  echo "Waiting for OLM operators to be ready..."
  while true; do
    local remaining=$(get_remaining_time)
    if [ $remaining -le 0 ]; then
      echo "Error: Global timeout reached while waiting for OLM"
      return 1
    fi
    
    # Check if OLM namespace exists and operators are ready
    if kubectl get namespace olm >/dev/null 2>&1; then
      echo "  OLM namespace exists, checking if operators are ready..."
      if kubectl wait --for=condition=Available deployment/olm-operator deployment/catalog-operator -n olm --timeout=30s 2>/dev/null; then
        echo "  OLM operators are ready"
        break
      else
        echo "  OLM operators not ready yet, will retry in 5s..."
      fi
    else
      echo "  OLM namespace doesn't exist yet, will retry in 5s..."
    fi
    sleep 5
  done
  
  kubectl auth can-i create namespace --all-namespaces
  kubectl create namespace "${NAMESPACE}" || true
  
  echo "Starting operator bundle deployment..."
  if ! operator-sdk run bundle "${OPERATOR_BUNDLE_IMAGE}" --namespace "${NAMESPACE}" --timeout "${TIMEOUT}"; then
    echo "Error: Failed to deploy operator bundle"
    return 1
  fi
  
  echo "Bundle deployment completed"
}

# Function to apply Tackle CR - waits for Tackle CRD as precondition
start_tackle() {
  echo "=== Starting Tackle CR Application ==="
  
  # Precondition: Wait for CRD to exist and be established
  echo "Waiting for Tackle CRD to be available..."
  while true; do
    local remaining=$(get_remaining_time)
    if [ $remaining -le 0 ]; then
      echo "Error: Global timeout reached while waiting for Tackle CRD"
      return 1
    fi
    
    if kubectl get customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io >/dev/null 2>&1; then
      echo "  Tackle CRD exists, waiting for it to be established..."
      if kubectl wait --for=condition=established customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io --timeout=30s 2>/dev/null; then
        echo "  Tackle CRD is established"
        break
      else
        echo "  Tackle CRD not established yet, will retry in 5s..."
      fi
    else
      echo "  Tackle CRD doesn't exist yet, will retry in 5s..."
    fi
    sleep 5
  done

  # Apply the Tackle CR
  echo "Applying Tackle custom resource..."
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

  echo "Tackle CR applied successfully"
}

# Function to wait for deployments with progress reporting
wait_for_deployments_with_progress() {
  local chunk_duration=30
  
  while true; do
    local remaining=$(get_remaining_time)
    if [ $remaining -le 0 ]; then
      echo "Global timeout reached while waiting for deployments"
      # Show what's not ready for debugging
      kubectl get deployments.apps -n "${NAMESPACE}" --no-headers | grep -v "1/1" || true
      return 1
    fi
    
    local wait_time=$chunk_duration
    # Don't wait longer than remaining global time
    if [ $wait_time -gt $remaining ]; then
      wait_time=$remaining
    fi
    
    local elapsed=$((GLOBAL_TIMEOUT_SECONDS - remaining))
    echo "Waiting for deployments... (${elapsed}s elapsed, ${remaining}s remaining)"
    
    # Try waiting for the chunk duration
    if kubectl wait \
      --namespace "${NAMESPACE}" \
      --selector="app.kubernetes.io/part-of=tackle" \
      --for=condition=Available \
      --timeout=${wait_time}s \
      deployments.apps 2>/dev/null; then
      echo "All deployments are now available!"
      return 0
    fi
    
    # Show status of what we're still waiting for
    echo "Still waiting for some deployments..."
    local pending_deployments
    pending_deployments=$(kubectl get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=tackle" \
      --no-headers -o custom-columns="NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas" \
      | awk '$2!=$3 {print $1 "(" $2 "/" $3 ")"}' || echo "unknown")
    
    if [ -n "$pending_deployments" ]; then
      echo "   Pending: $pending_deployments"
    fi
    
    # Show recent events that might explain delays
    echo "   Recent events:"
    kubectl get events --namespace="${NAMESPACE}" --sort-by='.lastTimestamp' \
      --field-selector reason!=Scheduled,reason!=Created,reason!=Started \
      | tail -3 | awk '{print "   " $0}' || echo "   (no events found)"
    
    if [ $remaining -gt $chunk_duration ]; then
      echo "   Continuing to wait..."
      echo ""
    fi
  done
}

# Function to install OLM
start_olm() {
  echo "=== Starting OLM Installation ==="
  echo "Installing OLM version ${OLM_VERSION}..."
  
  # Add timeout flag for operator-sdk (supported in newer versions)
  # Default is 2m which is too short for resource-constrained environments
  if operator-sdk olm install --version ${OLM_VERSION} --timeout 5m; then
    echo "OLM installation successful"
    return 0
  else
    echo "OLM installation failed"
    # Try to get more debug info about why it failed
    echo "Checking OLM pod status..."
    kubectl get pods -n olm --no-headers 2>/dev/null || true
    kubectl get events -n olm --sort-by='.lastTimestamp' | tail -10 2>/dev/null || true
    return 1
  fi
}

# Function to validate entire stack is ready
validate_full_stack() {
  echo "=== Validating Full Stack Readiness ==="
  
  # Get OLM namespace
  local olm_namespace
  olm_namespace=$(kubectl get clusterserviceversions.operators.coreos.com --all-namespaces | grep packageserver | awk '{print $1}')
  
  # Check if namespace was found
  if [ -z "${olm_namespace}" ]; then
    echo "Error: Could not determine OLM namespace"
    return 1
  fi
  
  echo "OLM namespace: ${olm_namespace}"
  
  # Validate OLM components in parallel
  echo "Validating OLM components..."
  kubectl wait --namespace "${olm_namespace}" --for=condition=Available deployment/olm-operator deployment/catalog-operator --timeout=60s &
  OLM_PID=$!
  kubectl wait --namespace "${olm_namespace}" --for='jsonpath={.status.phase}'=Succeeded clusterserviceversions.operators.coreos.com packageserver --timeout=60s &
  PKG_PID=$!
  
  if ! wait_for_all $OLM_PID $PKG_PID; then
    echo "Error: OLM validation failed"
    return 1
  fi
  
  # Validate Tackle components - operator and CR in parallel
  echo "Validating Tackle components..."
  kubectl wait --namespace "${NAMESPACE}" --for=condition=Available deployment/tackle-operator --timeout=60s &
  OP_PID=$!
  kubectl wait --namespace "${NAMESPACE}" --for=condition=Successful tackles.tackle.konveyor.io/tackle --timeout=120s &
  CR_PID=$!
  
  if ! wait_for_all $OP_PID $CR_PID; then
    echo "Error: Tackle validation failed"
    return 1
  fi
  
  # Validate all deployments
  echo "Validating all Tackle deployments..."
  wait_for_deployments_with_progress
  
  echo "Full stack validation completed successfully!"
}


# Main execution flow
echo "=== PHASE 1: Starting All Components ==="

# Create namespace early if it doesn't exist
kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

# Start OLM if not already present (check and install both in background for parallelism)
(kubectl get customresourcedefinitions.apiextensions.k8s.io clusterserviceversions.operators.coreos.com 2>/dev/null || (set +E; start_olm)) &
OLM_PID=$!

# Start bundle deployment (will wait for OLM CRDs)
( set +E; start_bundle ) &
BUNDLE_PID=$!

# Start Tackle CR application (will wait for Tackle CRD and operator)
( set +E; start_tackle ) &
TACKLE_PID=$!

echo "=== PHASE 2: Waiting for Background Processes ==="

# Wait for all processes - OLM first, then bundle, then tackle
if ! wait_for_all $OLM_PID $BUNDLE_PID $TACKLE_PID; then
  echo "Error: One or more background processes failed"
  exit 1
fi

echo "=== PHASE 3: Final Validation ==="
validate_full_stack
