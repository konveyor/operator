#!/bin/bash
set -e

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
TEST_FAILED=false

echo "=== Testing LLM Proxy with llemulator backend ==="

# Wait for services to be ready
wait_for_deployment() {
    local deployment=$1
    local retries=0
    local max_retries=30

    echo -n "Waiting for $deployment..."
    while [ $retries -lt $max_retries ]; do
        READY=$(kubectl get deployment $deployment -n $NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        DESIRED=$(kubectl get deployment $deployment -n $NAMESPACE -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

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

# Ensure all services are ready
wait_for_deployment tackle-hub
wait_for_deployment llm-proxy
wait_for_deployment llemulator

# Get hub URL
HUB_URL=""
if kubectl get ingress -n $NAMESPACE &>/dev/null; then
    INGRESS_HOST=$(kubectl get ingress tackle -n $NAMESPACE -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    if [ -n "$INGRESS_HOST" ]; then
        HUB_URL="http://$INGRESS_HOST"
    fi
fi

# Fallback to localhost with port-forward
if [ -z "$HUB_URL" ]; then
    echo "Using port-forward for hub access..."
    kubectl port-forward -n $NAMESPACE service/tackle-ui 8080:8080 &
    PF_HUB_PID=$!
    sleep 3
    HUB_URL="http://localhost:8080"
fi

echo "Hub URL: $HUB_URL"

# Clear password change requirement for admin user
echo "Configuring authentication..."
ADMIN_SECRET=$(kubectl get secret tackle-keycloak-sso -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

# Get admin token from Keycloak
ADMIN_TOKEN_RESPONSE=$(kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -X POST \
  http://tackle-keycloak-sso:8080/auth/realms/master/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=$ADMIN_SECRET" 2>/dev/null || echo "{}")

ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    # Get admin user ID in tackle realm
    ADMIN_USER_ID=$(kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s \
      http://tackle-keycloak-sso:8080/auth/admin/realms/tackle/users \
      -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[] | select(.username=="admin") | .id // empty')

    if [ -n "$ADMIN_USER_ID" ]; then
        # Clear required actions and reset password
        kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -X PUT \
          "http://tackle-keycloak-sso:8080/auth/admin/realms/tackle/users/$ADMIN_USER_ID" \
          -H "Authorization: Bearer $ADMIN_TOKEN" \
          -H "Content-Type: application/json" \
          -d '{"requiredActions": []}' &>/dev/null

        kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -X PUT \
          "http://tackle-keycloak-sso:8080/auth/admin/realms/tackle/users/$ADMIN_USER_ID/reset-password" \
          -H "Authorization: Bearer $ADMIN_TOKEN" \
          -H "Content-Type: application/json" \
          -d '{"type": "password", "value": "Passw0rd!", "temporary": false}' &>/dev/null
    fi
fi

# Test hub authentication
echo "Testing hub authentication..."
HUB_AUTH_RESPONSE=$(curl -s -X POST \
  $HUB_URL/hub/auth/login \
  -H "Content-Type: application/json" \
  -d '{"user": "admin", "password": "Passw0rd!"}' \
  -D /tmp/auth_headers.txt 2>/dev/null)

# Extract token
ACCESS_TOKEN=$(grep -i "authorization" /tmp/auth_headers.txt 2>/dev/null | sed 's/.*Bearer //' | tr -d '\r\n')
if [ -z "$ACCESS_TOKEN" ]; then
    ACCESS_TOKEN=$(echo "$HUB_AUTH_RESPONSE" | jq -r '.token // .access_token // empty' 2>/dev/null)
fi

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "ERROR: Failed to get authentication token"
    TEST_FAILED=true
else
    echo "Authentication successful"
fi

# Test LLM proxy with all configured responses
echo "Testing LLM proxy endpoint with sequential responses..."
if [ -n "$ACCESS_TOKEN" ]; then
    MODEL_ID=$(kubectl get configmap llm-proxy-client -n $NAMESPACE -o jsonpath='{.data.config\.json}' 2>/dev/null | jq -r '.model' 2>/dev/null || echo "gpt-4o")

    # Expected responses in order (from setup-llemulator.sh)
    EXPECTED_RESPONSES=(
        "This is a test response from llemulator for LLM proxy testing."
        "The integration between llm-proxy and llemulator is working correctly."
        "Test successful: llm-proxy can communicate with the mock OpenAI endpoint."
    )

    # Test each expected response
    for i in "${!EXPECTED_RESPONSES[@]}"; do
        echo "  Test $((i+1))/3: Verifying response sequence..."

        PROXY_RESPONSE=$(curl -s -X POST ${HUB_URL}/llm-proxy/v1/chat/completions \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{
            \"model\": \"$MODEL_ID\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Test message $((i+1))\"}],
            \"max_tokens\": 100
          }" 2>&1)

        if echo "$PROXY_RESPONSE" | grep -q "choices"; then
            CONTENT=$(echo "$PROXY_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

            if [ "$CONTENT" = "${EXPECTED_RESPONSES[$i]}" ]; then
                echo "    ✓ Response $((i+1)) matches expected: correct"
            else
                echo "    ✗ Response $((i+1)) mismatch!"
                echo "      Expected: ${EXPECTED_RESPONSES[$i]}"
                echo "      Received: $CONTENT"
                TEST_FAILED=true
            fi
        else
            echo "    ✗ Response $((i+1)) failed - invalid response structure"
            echo "      Response: $(echo "$PROXY_RESPONSE" | head -1)"
            TEST_FAILED=true
        fi
    done

    if [ "$TEST_FAILED" != true ]; then
        echo "LLM proxy test: PASS - All responses verified"
    else
        echo "LLM proxy test: FAIL - Response verification failed"
    fi
fi

# Test security (invalid token rejection)
echo "Testing security (invalid token rejection)..."
INVALID_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST ${HUB_URL}/llm-proxy/v1/chat/completions \
  -H "Authorization: Bearer invalid-token-12345" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4o\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Test\"}],
    \"max_tokens\": 5
  }")

if [ "$INVALID_STATUS" = "401" ] || [ "$INVALID_STATUS" = "403" ] || [ "$INVALID_STATUS" = "302" ]; then
    echo "Security test: PASS (HTTP $INVALID_STATUS)"
else
    echo "Security test: FAIL (HTTP $INVALID_STATUS - expected 401/403/302)"
    TEST_FAILED=true
fi

# Cleanup port-forwards
if [ -n "$PF_HUB_PID" ]; then
    kill $PF_HUB_PID 2>/dev/null || true
fi

# Summary
echo ""
echo "=== Test Summary ==="
if [ "$TEST_FAILED" = true ]; then
    echo "Some tests failed. Please review the output above."
    exit 1
else
    echo "All tests passed successfully!"
    exit 0
fi
