#!/usr/bin/env bash
# Create an application in the Hub, for tests that need something to run
# against. Nothing agentic about it: analysis, discovery and agentic runs all
# want the same thing.
#
# Reaches the Hub in-cluster rather than through a route, so this needs no
# ingress. The Service is ${app_name}-hub, which differs per product, so it is
# found by the label the operator sets.
set -euo pipefail

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
# Either hand over the application as the Hub would take it, or let the
# defaults build the common case. Taking the Hub's own schema means there is
# no seeding format here to invent or maintain.
APP_JSON="${APP_JSON:-}"
APP_NAME="${APP_NAME:-e2e-app}"
APP_REPO="${APP_REPO:-https://github.com/konveyor/tackle-testapp-public.git}"
APP_BRANCH="${APP_BRANCH:-main}"

if [ -z "${APP_JSON}" ]; then
  APP_JSON="{\"name\": \"${APP_NAME}\",
             \"repository\": {\"kind\": \"git\",
                              \"url\": \"${APP_REPO}\",
                              \"branch\": \"${APP_BRANCH}\"}}"
else
  # Parsed, not grepped: the Hub's schema nests "name" under businessService,
  # tags, owner and identities, and a regex over the whole document picks
  # whichever comes last.
  APP_NAME=$(APP_JSON="${APP_JSON}" python3 -c \
    'import json,os,sys; sys.stdout.write(json.loads(os.environ["APP_JSON"])["name"])')
fi

HUB_SVC=$(kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/component=hub \
  -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | head -1)
if [ -z "${HUB_SVC}" ]; then
  echo "No Service labelled app.kubernetes.io/component=hub in ${NAMESPACE}" >&2
  exit 1
fi
HUB_PORT=$(kubectl -n "${NAMESPACE}" get svc "${HUB_SVC}" \
  -o jsonpath='{.spec.ports[?(@.name=="api")].port}')
HUB_SCHEME=http
[ "${HUB_PORT}" = "8443" ] && HUB_SCHEME=https

LOCAL_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
kubectl -n "${NAMESPACE}" port-forward "svc/${HUB_SVC}" "${LOCAL_PORT}:${HUB_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
sleep 3

HUB="${HUB_SCHEME}://localhost:${LOCAL_PORT}"
echo "=== Seeding ${APP_NAME}"

CODE=$(curl -sk -o /tmp/hub-apps.json -w '%{http_code}' "${HUB}/applications")
case "${CODE}" in
  200) : ;;
  401|403)
    echo "Hub refused the request (HTTP ${CODE}). It is running with" >&2
    echo "feature_auth_required, so seeding needs a token." >&2
    exit 1
    ;;
  *)
    echo "Hub returned HTTP ${CODE} listing applications" >&2
    exit 1
    ;;
esac

if APP_NAME="${APP_NAME}" python3 -c \
  'import json,os,sys; sys.exit(0 if any(a.get("name")==os.environ["APP_NAME"] for a in json.load(open("/tmp/hub-apps.json"))) else 1)'; then
  echo "  ${APP_NAME} already exists"
  exit 0
fi

CODE=$(curl -sk -o /tmp/hub-post.json -w '%{http_code}' -X POST "${HUB}/applications" \
  -H "Content-Type: application/json" \
  -d "${APP_JSON}")
if [ "${CODE}" != "200" ] && [ "${CODE}" != "201" ]; then
  echo "Creating ${APP_NAME} failed (HTTP ${CODE}):" >&2
  cat /tmp/hub-post.json >&2
  exit 1
fi
echo "  created ${APP_NAME}"
