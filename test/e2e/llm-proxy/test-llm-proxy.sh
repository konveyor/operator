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
wait_for_deployment tackle-keycloak-sso

# Wait for Keycloak to be fully ready (not just the pod, but the service responding)
echo -n "Waiting for Keycloak to be ready..."
KC_READY=false
for i in $(seq 1 30); do
    KC_STATUS=$(kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -o /dev/null -w "%{http_code}" \
        http://tackle-keycloak-sso:8080/auth/realms/tackle/.well-known/openid-configuration 2>/dev/null || echo "000")
    if [ "$KC_STATUS" = "200" ]; then
        echo " ready"
        KC_READY=true
        break
    fi
    echo -n "."
    sleep 5
done
if [ "$KC_READY" != true ]; then
    echo " timeout (Keycloak may not be fully ready)"
fi

# Wait for admin user to exist in tackle realm (created by keycloak job)
echo -n "Waiting for admin user in tackle realm..."
ADMIN_EXISTS=false
ADMIN_SECRET=$(kubectl get secret tackle-keycloak-sso -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
for i in $(seq 1 30); do
    # Get admin token
    ADMIN_TOKEN_RESP=$(kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -X POST \
      http://tackle-keycloak-sso:8080/auth/realms/master/protocol/openid-connect/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password&client_id=admin-cli&username=admin&password=$ADMIN_SECRET" 2>/dev/null || echo "{}")

    if echo "$ADMIN_TOKEN_RESP" | grep -q "access_token"; then
        TEMP_TOKEN=$(echo "$ADMIN_TOKEN_RESP" | jq -r '.access_token' 2>/dev/null || true)
        if [ -n "$TEMP_TOKEN" ]; then
            # Check for admin user in tackle realm
            USERS=$(kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s \
              "http://tackle-keycloak-sso:8080/auth/admin/realms/tackle/users?username=admin" \
              -H "Authorization: Bearer $TEMP_TOKEN" 2>/dev/null || echo "[]")
            if echo "$USERS" | grep -q '"username":"admin"'; then
                echo " found"
                ADMIN_EXISTS=true
                break
            fi
        fi
    fi
    echo -n "."
    sleep 5
done
if [ "$ADMIN_EXISTS" != true ]; then
    echo " timeout (admin user may not exist yet)"
fi

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
# ADMIN_SECRET was already retrieved in the wait loop above

if [ -z "$ADMIN_SECRET" ]; then
    echo "  Warning: Could not get Keycloak admin secret, skipping admin user configuration"
else
    # Always try to configure admin user (even if wait timed out, user might exist now)
    # Get admin token from Keycloak
    ADMIN_TOKEN_RESPONSE=$(kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -X POST \
      http://tackle-keycloak-sso:8080/auth/realms/master/protocol/openid-connect/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password" \
      -d "client_id=admin-cli" \
      -d "username=admin" \
      -d "password=$ADMIN_SECRET" 2>/dev/null || echo "{}")

    # Safely extract token (handle non-JSON responses)
    if echo "$ADMIN_TOKEN_RESPONSE" | grep -q "access_token"; then
        ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || true)
    else
        ADMIN_TOKEN=""
        echo "  Warning: Could not get Keycloak admin token (response: $(echo "$ADMIN_TOKEN_RESPONSE" | head -c 200))"
    fi

    if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
        echo "  Got Keycloak admin token, configuring admin user..."
        # Get admin user ID in tackle realm
        USERS_RESPONSE=$(kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s \
          http://tackle-keycloak-sso:8080/auth/admin/realms/tackle/users \
          -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null || echo "[]")

        if echo "$USERS_RESPONSE" | grep -q "username"; then
            ADMIN_USER_ID=$(echo "$USERS_RESPONSE" | jq -r '.[] | select(.username=="admin") | .id // empty' 2>/dev/null || true)
        else
            ADMIN_USER_ID=""
        fi

        if [ -n "$ADMIN_USER_ID" ]; then
            echo "  Found admin user ID: $ADMIN_USER_ID"
            # Clear required actions and reset password
            kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -X PUT \
              "http://tackle-keycloak-sso:8080/auth/admin/realms/tackle/users/$ADMIN_USER_ID" \
              -H "Authorization: Bearer $ADMIN_TOKEN" \
              -H "Content-Type: application/json" \
              -d '{"requiredActions": []}' &>/dev/null || true

            kubectl exec -n $NAMESPACE deployment/tackle-hub -- curl -s -X PUT \
              "http://tackle-keycloak-sso:8080/auth/admin/realms/tackle/users/$ADMIN_USER_ID/reset-password" \
              -H "Authorization: Bearer $ADMIN_TOKEN" \
              -H "Content-Type: application/json" \
              -d '{"type": "password", "value": "Passw0rd!", "temporary": false}' &>/dev/null || true
            echo "  Admin user configured"
        else
            echo "  Warning: Could not find admin user in tackle realm"
        fi
    else
        echo "  Warning: Skipping admin user configuration (no admin token)"
    fi
fi

# Test hub authentication (with retries since Keycloak may need time)
echo "Testing hub authentication..."
ACCESS_TOKEN=""
for attempt in 1 2 3; do
    echo "  Attempt $attempt/3..."
    HUB_AUTH_RESPONSE=$(curl -s -X POST \
      $HUB_URL/hub/auth/login \
      -H "Content-Type: application/json" \
      -d '{"user": "admin", "password": "Passw0rd!"}' \
      --connect-timeout 10 \
      --max-time 30 \
      -D /tmp/auth_headers.txt -w "\n%{http_code}" 2>/dev/null || echo "CURL_FAILED")

    # Extract HTTP status code (last line)
    HTTP_STATUS=$(echo "$HUB_AUTH_RESPONSE" | tail -1)
    # Remove status code from response body
    HUB_AUTH_RESPONSE=$(echo "$HUB_AUTH_RESPONSE" | sed '$d')

    echo "  Hub auth response status: $HTTP_STATUS"

    # Check if curl failed or got non-2xx response
    if [ "$HTTP_STATUS" = "CURL_FAILED" ]; then
        echo "  Warning: curl failed to connect to hub"
    elif [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 400 ] 2>/dev/null; then
        echo "  Warning: Hub authentication failed with HTTP $HTTP_STATUS"
        echo "  Response preview: $(echo "$HUB_AUTH_RESPONSE" | head -c 200)"
    else
        # Extract token from headers first
        ACCESS_TOKEN=$(grep -i "authorization" /tmp/auth_headers.txt 2>/dev/null | sed 's/.*Bearer //' | tr -d '\r\n' || true)

        # If not in headers, try to parse from JSON body
        if [ -z "$ACCESS_TOKEN" ]; then
            # Only parse if response looks like JSON
            if echo "$HUB_AUTH_RESPONSE" | grep -q "^{"; then
                ACCESS_TOKEN=$(echo "$HUB_AUTH_RESPONSE" | jq -r '.token // .access_token // empty' 2>/dev/null || true)
            fi
        fi

        if [ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ]; then
            echo "Authentication successful"
            break
        fi
    fi

    if [ $attempt -lt 3 ]; then
        echo "  Retrying in 5 seconds..."
        sleep 5
    fi
done

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "ERROR: Failed to get authentication token after 3 attempts"
    echo "  Last response headers: $(cat /tmp/auth_headers.txt 2>/dev/null | head -10)"
    TEST_FAILED=true
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
