#!/usr/bin/env bash
# Emulator and Gateway, for a cluster that already has Konveyor installed with
# agentic_enabled and the Agent Sandbox CRD (install-konveyor.sh, behind
# INSTALL_AGENT_SANDBOX).
#
# A run also needs an application to run against. That is test data rather
# than agentic infrastructure, so it is ../seed-application.sh, exposed as
# the seed_application input on the install-konveyor action.
set -euo pipefail

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
TACKLE_NAME="${TACKLE_NAME:-tackle}"
LLEMULATOR_TOKEN="${LLEMULATOR_TOKEN:-not-a-real-key}"
LLEMULATOR_MODEL="${LLEMULATOR_MODEL:-test-model}"
GATEWAY_NAME="${GATEWAY_NAME:-llemulator}"
# Override to serve your own conversation (fabianvf/llemulator#3 tracks
# accepting YAML, which would make these readable).
LLEMULATOR_SCRIPT="${LLEMULATOR_SCRIPT:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying the emulator with an agentic conversation"
NAMESPACE="${NAMESPACE}" \
LLEMULATOR_TOKEN="${LLEMULATOR_TOKEN}" \
LLEMULATOR_SCRIPT="${LLEMULATOR_SCRIPT:-${HERE}/llemulator-script.json}" \
LLEMULATOR_DEBUG="${LLEMULATOR_DEBUG:-true}" \
  "${HERE}/../llm-proxy/setup-llemulator.sh"

# Before the Gateway, because nothing verifies it until the controller is
# running, and a Gateway that fails verification stays Ready=False for its
# generation - so one created too early cannot be rescued by re-applying
# (konveyor/agentic-controller#246). The CRD itself ships in the bundle.
echo "=== Waiting for the agentic controller"
if ! kubectl -n "${NAMESPACE}" wait "tackle/${TACKLE_NAME}" \
  --for=condition=AgenticControllerReady --timeout=600s; then
  # Disabled, AgentSandboxMissing, DefaultContentImageBindingInvalid and
  # DeploymentNotReady are distinguished, so the reason is the diagnosis.
  kubectl -n "${NAMESPACE}" get "tackle/${TACKLE_NAME}" -o \
    jsonpath='{range .status.conditions[?(@.type=="AgenticControllerReady")]}{.reason}: {.message}{"\n"}{end}'
  exit 1
fi

echo "=== Creating the Gateway"
# Recreate rather than apply when one is already failing: verification is
# settled per generation, and an unchanged spec is not a new generation.
READY=$(kubectl -n "${NAMESPACE}" get "gateway.konveyor.io/${GATEWAY_NAME}" -o \
  'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ -n "${READY}" ] && [ "${READY}" != "True" ]; then
  kubectl -n "${NAMESPACE}" delete "gateway.konveyor.io/${GATEWAY_NAME}" --ignore-not-found
fi

kubectl -n "${NAMESPACE}" create secret generic "${GATEWAY_NAME}-credentials" \
  --from-literal=api-key="${LLEMULATOR_TOKEN}" \
  --dry-run=client -o yaml | kubectl -n "${NAMESPACE}" apply -f -

kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: konveyor.io/v1alpha1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
spec:
  provider: openai
  # A base URL: no /v1, which the client appends.
  endpoint: http://llemulator.${NAMESPACE}.svc.cluster.local
  model:
    # Must be one the session above was scripted with, or runs fail with a
    # provider error that says nothing about the Gateway.
    name: ${LLEMULATOR_MODEL}
    tier: efficient
    contextWindow: 100000
  credentialRef:
    secretName: ${GATEWAY_NAME}-credentials
    key: api-key
YAML

if ! kubectl -n "${NAMESPACE}" wait "gateway.konveyor.io/${GATEWAY_NAME}" \
  --for=condition=Ready --timeout=300s; then
  kubectl -n "${NAMESPACE}" get "gateway.konveyor.io/${GATEWAY_NAME}" -o \
    'jsonpath={range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
  exit 1
fi

echo "=== Agentic fixtures ready"
kubectl -n "${NAMESPACE}" get gateways.konveyor.io,agents.konveyor.io
