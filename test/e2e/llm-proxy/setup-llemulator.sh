#!/bin/bash
set -e

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
LLEMULATOR_IMAGE="${LLEMULATOR_IMAGE:-quay.io/fabianvf/llemulator:latest}"

echo "=== Setting up llemulator in namespace $NAMESPACE ==="

# Check if already deployed
if kubectl get deployment llemulator -n $NAMESPACE &>/dev/null; then
    echo "llemulator already deployed, skipping deployment"
else
    echo "Deploying llemulator..."
    # Deploy llemulator
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llemulator
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llemulator
  template:
    metadata:
      labels:
        app: llemulator
    spec:
      containers:
      - name: llemulator
        image: ${LLEMULATOR_IMAGE}
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        - name: DEBUG
          value: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: llemulator
  namespace: ${NAMESPACE}
spec:
  selector:
    app: llemulator
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
EOF

    # Wait for llemulator to be ready
    echo "Waiting for llemulator deployment..."
    kubectl rollout status deployment/llemulator -n "${NAMESPACE}" --timeout=300s
fi

# Configure llemulator with test responses using port-forward
echo "Configuring llemulator..."

# Get the API key from the secret
API_KEY=$(kubectl get secret kai-api-keys -n "${NAMESPACE}" -o jsonpath='{.data.OPENAI_API_KEY}' 2>/dev/null | base64 -d || echo "dummy-key-for-llemulator")

# Start port-forward in background
kubectl port-forward -n "${NAMESPACE}" service/llemulator 8089:80 &
PF_PID=$!
sleep 3

# Configure with the correct token
RESPONSE=$(curl -s -X POST http://localhost:8089/_emulator/script \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "reset": true,
    "models": ["gpt-4o", "gpt-4", "gpt-3.5-turbo"],
    "responses": [
      "This is a test response from llemulator for LLM proxy testing.",
      "The integration between llm-proxy and llemulator is working correctly.",
      "Test successful: llm-proxy can communicate with the mock OpenAI endpoint."
    ]
  }')

if echo "$RESPONSE" | grep -q "error"; then
  echo "Warning: Failed to configure llemulator: $RESPONSE"
else
  echo "llemulator configured with API key: ${API_KEY:0:10}..."
fi

# Kill port-forward
kill $PF_PID 2>/dev/null || true

echo "llemulator setup complete"
