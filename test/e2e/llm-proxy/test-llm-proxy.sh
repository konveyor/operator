#!/bin/bash
set -e

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
TEST_FAILED=false

echo "=== Testing LLM Proxy via hub /services/llm-proxy ==="

wait_for_deployment() {
    local deployment=$1
    local retries=0
    local max_retries=30

    echo -n "Waiting for $deployment..."
    while [ $retries -lt $max_retries ]; do
        READY=$(kubectl get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        DESIRED=$(kubectl get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

        if [ "$READY" == "$DESIRED" ] && [ "$READY" != "0" ]; then
            echo " ready"
            return 0
        fi

        retries=$((retries + 1))
        sleep 5
        echo -n "."
    done

    echo " timeout"
    return 1
}

wait_for_deployment tackle-hub
wait_for_deployment tackle-ui
wait_for_deployment llm-proxy
wait_for_deployment llemulator

# Reach the hub through the UI's /hub reverse-proxy -- the same path real
# clients use. Port-forward the UI Service, then everything goes through
# /hub/...; the UI passes the Authorization header straight through to the hub.
echo "Using port-forward to the UI service..."
kubectl port-forward -n "$NAMESPACE" service/tackle-ui 8080:8080 &
PF_HUB_PID=$!
sleep 3
HUB_URL="http://localhost:8080"

echo "Hub URL: $HUB_URL"

# Authenticate as the seeded 'admin' user via HTTP Basic Auth and exchange that
# for a long-lived API key (PAT) via POST /hub/auth/tokens. Use the API key as a
# Bearer token for subsequent /hub/services/llm-proxy calls — this mirrors how
# real clients are expected to use the hub: short-lived credential at the door,
# API key for service calls.
echo "Requesting API key from the hub..."
APIKEY=$(curl -s -X POST "${HUB_URL}/hub/auth/tokens" \
  -H "Authorization: Basic $(printf 'admin:admin' | base64)" \
  -H "Content-Type: application/json" \
  -d '{}' | jq -r '.token // empty')
if [ -z "$APIKEY" ]; then
    echo "FAIL: did not receive an API key from /hub/auth/tokens" >&2
    if [ -n "$PF_HUB_PID" ]; then kill $PF_HUB_PID 2>/dev/null || true; fi
    exit 1
fi
echo "Got API key (first 12 chars): ${APIKEY:0:12}..."
AUTH_HEADER="Authorization: Bearer $APIKEY"

MODEL_ID=$(kubectl get configmap llm-proxy-client -n "$NAMESPACE" -o jsonpath='{.data.config\.json}' 2>/dev/null | jq -r '.model' 2>/dev/null || echo "gpt-4o")

EXPECTED_RESPONSES=(
    "This is a test response from llemulator for LLM proxy testing."
    "The integration between llm-proxy and llemulator is working correctly."
    "Test successful: llm-proxy can communicate with the mock OpenAI endpoint."
)

echo "Testing LLM proxy endpoint with sequential responses..."
for i in "${!EXPECTED_RESPONSES[@]}"; do
    echo "  Test $((i+1))/3: Verifying response sequence..."

    HTTP_RESPONSE=$(curl -s -w $'\n%{http_code}' -X POST "${HUB_URL}/hub/services/llm-proxy/v1/chat/completions" \
      -H "$AUTH_HEADER" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$MODEL_ID\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Test message $((i+1))\"}],
        \"max_tokens\": 100
      }")
    HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -n1)
    PROXY_RESPONSE=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')

    if echo "$PROXY_RESPONSE" | grep -q "choices"; then
        CONTENT=$(echo "$PROXY_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

        if [ "$CONTENT" = "${EXPECTED_RESPONSES[$i]}" ]; then
            echo "    ✓ Response $((i+1)) matches expected"
        else
            echo "    ✗ Response $((i+1)) mismatch!"
            echo "      Expected: ${EXPECTED_RESPONSES[$i]}"
            echo "      Received: $CONTENT"
            TEST_FAILED=true
        fi
    else
        echo "    ✗ Response $((i+1)) failed (HTTP $HTTP_CODE)"
        echo "      Body: $(printf '%s' "$PROXY_RESPONSE" | head -c 400)"
        TEST_FAILED=true
    fi
done

if [ "$TEST_FAILED" != true ]; then
    echo "LLM proxy test: PASS - All responses verified"
else
    echo "LLM proxy test: FAIL - Response verification failed"
fi

# Security check: hit the hub directly with an invalid Bearer token and assert
# the hub itself rejects it with 401/403. We deliberately bypass the UI here —
# the UI's /hub proxy can choose to 302 unrecognized tokens to its OIDC login
# page (browser-UX), which is not the same as the hub refusing the request.
# What we want to assert is the hub's own auth enforcement on /services/...
echo "Testing security (invalid credentials rejection at the hub)..."
kubectl port-forward -n "$NAMESPACE" service/tackle-hub 8089:8080 > /dev/null 2>&1 &
PF_HUB_DIRECT_PID=$!
sleep 3
INVALID_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:8089/services/llm-proxy/v1/chat/completions" \
  -H "Authorization: Bearer invalid-token-12345" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Test\"}],
    \"max_tokens\": 5
  }")
kill $PF_HUB_DIRECT_PID 2>/dev/null || true

if [ "$INVALID_STATUS" = "401" ] || [ "$INVALID_STATUS" = "403" ]; then
    echo "Security test: PASS (HTTP $INVALID_STATUS)"
else
    echo "Security test: FAIL (HTTP $INVALID_STATUS - expected 401/403)"
    TEST_FAILED=true
fi

if [ -n "$PF_HUB_PID" ]; then
    kill $PF_HUB_PID 2>/dev/null || true
fi

echo ""
echo "=== Test Summary ==="
if [ "$TEST_FAILED" = true ]; then
    echo "FAILED: One or more tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
