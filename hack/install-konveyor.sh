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

# Configuration for retry and wait behavior
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-600}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Please install kubectl. See https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi

if ! command -v operator-sdk >/dev/null 2>&1; then
  echo "Please install operator-sdk. See https://sdk.operatorframework.io/docs/installation/"
  exit 1
fi

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

# Function to deploy bundle - waits for OLM CRDs as precondition
start_bundle() {
  echo "=== Starting Bundle Deployment ==="
  
  # Precondition: Wait for OLM CRDs to exist and be established
  echo "Waiting for OLM CRDs to be available..."
  local elapsed=0
  local timeout=300
  while [ $elapsed -lt $timeout ]; do
    if kubectl get customresourcedefinitions.apiextensions.k8s.io/clusterserviceversions.operators.coreos.com >/dev/null 2>&1; then
      # CRD exists, now wait for it to be established
      kubectl wait --for=condition=established customresourcedefinitions.apiextensions.k8s.io/clusterserviceversions.operators.coreos.com --timeout=30s && break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  
  if [ $elapsed -ge $timeout ]; then
    echo "Error: OLM CRDs did not become available within ${timeout}s"
    return 1
  fi
  
  kubectl auth can-i create namespace --all-namespaces
  kubectl create namespace "${NAMESPACE}" || true
  
  echo "Starting operator bundle deployment..."
  operator-sdk run bundle "${OPERATOR_BUNDLE_IMAGE}" --namespace "${NAMESPACE}" --timeout "${TIMEOUT}"
  
  echo "Bundle deployment completed"
}

# Function to apply Tackle CR - waits for Tackle CRD as precondition
start_tackle() {
  echo "=== Starting Tackle CR Application ==="
  
  # Precondition: Wait for CRD to exist and be established
  echo "Waiting for Tackle CRD to be available..."
  local elapsed=0
  local timeout=300
  while [ $elapsed -lt $timeout ]; do
    if kubectl get customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io >/dev/null 2>&1; then
      # CRD exists, now wait for it to be established
      kubectl wait --for=condition=established customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io --timeout=30s && break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  
  if [ $elapsed -ge $timeout ]; then
    echo "Error: Tackle CRD did not become available within ${timeout}s"
    return 1
  fi

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

  # Show what we created
  kubectl get --namespace "${NAMESPACE}" -o yaml tackles.tackle.konveyor.io/tackle
  echo "Tackle CR applied successfully"
}

# Function to wait for deployments with progress reporting
wait_for_deployments_with_progress() {
  local total_timeout=$DEPLOYMENT_TIMEOUT
  local chunk_duration=30
  local elapsed=0
  
  while [ $elapsed -lt $total_timeout ]; do
    local remaining=$((total_timeout - elapsed))
    local wait_time=$chunk_duration
    
    # Don't wait longer than remaining time
    if [ $wait_time -gt $remaining ]; then
      wait_time=$remaining
    fi
    
    echo "Waiting for deployments... (${elapsed}s/${total_timeout}s elapsed)"
    
    # Try waiting for the chunk duration
    if kubectl wait \
      --namespace "${NAMESPACE}" \
      --selector="app.kubernetes.io/part-of=tackle" \
      --for=condition=Available \
      --timeout=${wait_time}s \
      deployments.apps 2>/dev/null; then
      echo "All deployments are now available!"
      kubectl get deployments.apps -n "${NAMESPACE}" -o yaml
      return 0
    fi
    
    # Update elapsed time
    elapsed=$((elapsed + wait_time))
    
    # Show status of what we're still waiting for
    echo "Still waiting for some deployments after ${elapsed}s..."
    local pending_deployments=$(kubectl get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=tackle" \
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
    
    if [ $elapsed -lt $total_timeout ]; then
      echo "   Continuing to wait..."
      echo ""
    fi
  done
  
  echo "Timed out waiting for deployments after ${total_timeout}s"
  kubectl get deployments.apps -n "${NAMESPACE}"
  return 1
}

# Function to install OLM with retry logic
start_olm() {
  local attempt=1
  
  echo "=== Starting OLM Installation ==="
  while [ $attempt -le $MAX_RETRIES ]; do
    echo "Attempt $attempt of $MAX_RETRIES: Installing OLM version ${OLM_VERSION}..."
    if operator-sdk olm install --version ${OLM_VERSION}; then
      echo "OLM installation successful"
      return 0
    fi
    
    if [ $attempt -lt $MAX_RETRIES ]; then
      echo "OLM installation failed, cleaning up before retry..."
      # Uninstall OLM to clean up partial installation
      operator-sdk olm uninstall || true
      echo "Retrying..."
    fi
    attempt=$((attempt + 1))
  done
  
  echo "Failed to install OLM after $MAX_RETRIES attempts"
  return 1
}

# Function to validate entire stack is ready
validate_full_stack() {
  echo "=== Validating Full Stack Readiness ==="
  
  # Get OLM namespace
  local olm_namespace
  olm_namespace=$(kubectl get clusterserviceversions.operators.coreos.com --all-namespaces | grep packageserver | awk '{print $1}')
  echo "OLM namespace: ${olm_namespace}"
  
  # Validate OLM components in parallel
  echo "Validating OLM components..."
  kubectl wait --namespace "${olm_namespace}" --for=condition=Available deployment/olm-operator deployment/catalog-operator --timeout=60s &
  OLM_PID=$!
  kubectl wait --namespace "${olm_namespace}" --for='jsonpath={.status.phase}'=Succeeded clusterserviceversions.operators.coreos.com packageserver --timeout=60s &
  PKG_PID=$!
  wait $OLM_PID $PKG_PID
  
  # Validate Tackle components - operator and CR in parallel
  echo "Validating Tackle components..."
  kubectl wait --namespace "${NAMESPACE}" --for=condition=Available deployment/tackle-operator --timeout=60s &
  OP_PID=$!
  kubectl wait --namespace "${NAMESPACE}" --for=condition=Successful tackles.tackle.konveyor.io/tackle --timeout=120s &
  CR_PID=$!
  wait $OP_PID $CR_PID
  
  # Validate all deployments
  echo "Validating all Tackle deployments..."
  wait_for_deployments_with_progress
  
  echo "Full stack validation completed successfully!"
}

# Function to pre-pull a single image using kubectl
prepull_image() {
  local image="$1"
  local pod_name="prepull-$(echo "$image" | md5sum | cut -c1-8)"
  
  # Create pod to trigger image pull
  kubectl run "$pod_name" \
    --image="$image" \
    --restart=Never \
    --command -- /bin/sh -c "exit 0" \
    >/dev/null 2>&1
  
  # Wait for pod to complete (image pulled) or timeout
  kubectl wait --for=condition=Ready pod/"$pod_name" --timeout=60s >/dev/null 2>&1 || true
  
  # Clean up the pod
  kubectl delete pod "$pod_name" --ignore-not-found=true >/dev/null 2>&1
}

# Function to start pre-pulling images in background
start_image_prepulls() {
  # Only prepull if we're in a local environment (minikube/kind)
  if kubectl get nodes -o json | grep -q "minikube\|kind" 2>/dev/null; then
    echo "Pre-pulling images in background (best effort)..."
    
    # Core images that are almost always used
    prepull_image "${OPERATOR_BUNDLE_IMAGE}" &
    prepull_image "quay.io/konveyor/tackle2-operator:latest" &
    prepull_image "quay.io/konveyor/tackle2-hub:latest" &
    prepull_image "quay.io/sclorg/postgresql-15-c9s:latest" &
    prepull_image "quay.io/konveyor/tackle2-ui:latest" &
    prepull_image "quay.io/konveyor/tackle2-addon-analyzer:latest" &
    
    # Auth-related images
    prepull_image "quay.io/keycloak/keycloak:26.1" &
    prepull_image "quay.io/konveyor/tackle-keycloak-init:latest" &
    prepull_image "quay.io/openshift/origin-oauth-proxy:latest" &
    
    # KAI/LLM-related images
    prepull_image "quay.io/konveyor/kai-solution-server:latest" &
    prepull_image "docker.io/llamastack/distribution-starter:latest" &
  fi
}

# Main execution flow
echo "=== PHASE 1: Starting All Components ==="

# Create namespace early if it doesn't exist
kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

# Start image pre-pulls in background (all async)
start_image_prepulls

# Start OLM if not already present
kubectl get customresourcedefinitions.apiextensions.k8s.io clusterserviceversions.operators.coreos.com || start_olm

# Start bundle deployment (will wait for OLM CRDs)
start_bundle &
BUNDLE_PID=$!

# Start Tackle CR application (will wait for Tackle CRD and operator)
start_tackle &
TACKLE_PID=$!

echo "=== PHASE 2: Waiting for Background Processes ==="
wait $BUNDLE_PID
wait $TACKLE_PID

echo "=== PHASE 3: Final Validation ==="
validate_full_stack
