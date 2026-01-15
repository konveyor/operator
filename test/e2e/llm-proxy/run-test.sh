#!/bin/bash
set -e

# This script runs the complete LLM proxy integration test
# It assumes the operator is already installed with OLM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-konveyor-tackle}"

echo "=== Running LLM Proxy Integration Test ==="
echo "Namespace: $NAMESPACE"
echo ""

# Step 1: Ensure API key secret exists
echo "Step 1: Ensuring API key secret exists..."
kubectl create secret generic kai-api-keys \
  --from-literal=OPENAI_API_KEY=dummy-key-for-llemulator \
  -n $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Setup llemulator
echo ""
echo "Step 2: Setting up llemulator..."
"${SCRIPT_DIR}/setup-llemulator.sh"

# Step 3: Check if Tackle CR exists and update if needed for standalone runs
echo ""
echo "Step 3: Checking Tackle CR configuration..."
if ! kubectl get tackles.tackle.konveyor.io tackle -n "${NAMESPACE}" &>/dev/null; then
  echo "Creating Tackle CR with llemulator configuration..."
  cat <<EOF | kubectl apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: ${NAMESPACE}
spec:
  feature_auth_required: true
  kai_solution_server_enabled: true
  kai_llm_proxy_enabled: true
  kai_llm_model: gpt-4o
  kai_llm_provider: openai
  kai_llm_baseurl: http://llemulator.konveyor-tackle.svc.cluster.local/v1
EOF
else
  # Check if it needs llemulator configuration
  CURRENT_BASEURL=$(kubectl get tackles.tackle.konveyor.io tackle -n "${NAMESPACE}" -o jsonpath='{.spec.kai_llm_baseurl}' 2>/dev/null || echo "")
  if [[ "$CURRENT_BASEURL" != *"llemulator"* ]]; then
    echo "Updating Tackle CR to use llemulator..."
    kubectl patch tackles.tackle.konveyor.io tackle -n "${NAMESPACE}" --type=merge -p '{
      "spec": {
        "kai_llm_proxy_enabled": true,
        "kai_llm_baseurl": "http://llemulator.konveyor-tackle.svc.cluster.local/v1"
      }
    }'
  else
    echo "Tackle CR already configured for llemulator"
  fi
fi

# Step 4: Wait for reconciliation
echo ""
echo "Step 4: Waiting for Tackle reconciliation..."
kubectl wait --for=condition=Successful tackles.tackle.konveyor.io/tackle \
  -n "${NAMESPACE}" \
  --timeout=300s || true

# Step 5: Run tests
echo ""
echo "Step 5: Running tests..."
"${SCRIPT_DIR}/test-llm-proxy.sh"
