#!/bin/bash
set -e

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
LLEMULATOR_IMAGE="${LLEMULATOR_IMAGE:-quay.io/fabianvf/llemulator:latest}"
# The emulator scopes a session to the bearer token and answers nothing until
# a script is loaded under it, so a caller wanting its own responses needs
# both. Unset keeps the llm-proxy behaviour below.
LLEMULATOR_SCRIPT="${LLEMULATOR_SCRIPT:-}"
LLEMULATOR_TOKEN="${LLEMULATOR_TOKEN:-}"
# Log every request body. Worth it for a caller whose failure mode is "the
# agent did something unexpected".
LLEMULATOR_DEBUG="${LLEMULATOR_DEBUG:-false}"

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
          value: "${LLEMULATOR_DEBUG}"
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
if [ -n "${LLEMULATOR_TOKEN}" ]; then
  API_KEY="${LLEMULATOR_TOKEN}"
else
  API_KEY=$(kubectl get secret kai-api-keys -n "${NAMESPACE}" -o jsonpath='{.data.OPENAI_API_KEY}' 2>/dev/null | base64 -d || echo "dummy-key-for-llemulator")
fi

# A fixed local port collides with whatever else is being forwarded, and the
# symptom is an HTTP error from an unrelated service.
LOCAL_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
kubectl port-forward -n "${NAMESPACE}" service/llemulator "${LOCAL_PORT}:80" &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
sleep 3

# Configure with the correct token
if [ -n "${LLEMULATOR_SCRIPT}" ]; then
  RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "http://localhost:${LOCAL_PORT}/_emulator/script" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "@${LLEMULATOR_SCRIPT}")
else
  RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "http://localhost:${LOCAL_PORT}/_emulator/script" \
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
fi
HTTP_CODE=$(printf '%s' "${RESPONSE}" | tail -1)
RESPONSE=$(printf '%s' "${RESPONSE}" | sed '$d')

# Fatal, not a warning: the emulator answers nothing until a script is loaded
# under this token, so a silent failure here resurfaces as a Gateway that
# fails verification - which is terminal for its generation.
if [ "${HTTP_CODE}" != "200" ] || echo "$RESPONSE" | grep -q '"error"'; then
  echo "Failed to configure llemulator (HTTP ${HTTP_CODE}): $RESPONSE" >&2
  exit 1
fi
echo "llemulator configured with API key: ${API_KEY:0:10}..."

kill "$PF_PID" 2>/dev/null || true
trap - EXIT

echo "llemulator setup complete"
