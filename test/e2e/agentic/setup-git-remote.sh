#!/usr/bin/env bash
# An in-cluster git remote the harness can actually push to, and an
# application pointing at it.
#
# Why this exists: the harness pre-flights write access before the stage runs
# (konveyor/agentic-controller#248). It opens a git-receive-pack session and
# fails the run on an explicit refusal, so a public read-only remote - which
# is what an application seeded against github.com/konveyor/tackle-testapp-public
# with no source credential resolves to - stops every run before the agent
# takes a turn:
#
#   git write access: no write access to <url> for branch <branch>: the
#   application has no source credential
#
# That is the pre-flight working. The fixture was the thing that was wrong:
# it could never have supported a run that writes, and only looked healthy
# because the e2e prompt happens to change no files, so the final push was
# skipped and nothing ever asked for write access.
#
# `git daemon --enable=receive-pack` serves anonymous read *and* write over
# the git protocol. The pre-flight builds its transport from the URL scheme
# (transport.NewEndpoint then client.NewClient), and go-git's registry covers
# git://, so the probe is a real receive-pack handshake that succeeds without
# a credential. No credential to mint, no secret to rotate, no image to build
# - and a run that does write gets a push that genuinely lands.
#
# The deliberate trade: this exercises the anonymous path, not the
# credentialed one. A fixture that proves a *token* can push needs a server
# with accounts (gitea) and is a bigger piece of machinery; worth doing
# separately if we want coverage of the credential resolution itself, which
# is what konveyor/agentic-controller#247 was actually about.
#
# Which makes one thing load-bearing: the application must have NO source
# credential attached. The harness's Credentials.Auth() returns an
# *http.BasicAuth as soon as an identity resolves, and the git:// transport
# rejects that with "invalid auth method" - which the pre-flight classifies
# as inconclusive rather than a refusal, so the run starts anyway and dies
# at the final push instead. Attaching an identity here is strictly worse
# than attaching none.
#
# Standalone, and not called from setup-agentic.sh: this repoints an
# application, which should happen because a caller asked for it and not as a
# side effect of setting up an emulator. Run it after setup-agentic.sh, which
# is where the application is expected to already exist.
set -euo pipefail

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
# The application the agentic e2e runs against. Repointed if it already
# exists, because install-konveyor's seed_application may have created it
# against a public URL before this script runs, and the ordering of those two
# is not ours to rely on.
APP_NAME="${APP_NAME:-agentic-e2e}"
# Mirrored into the in-cluster remote, so the agent sees a real project rather
# than an empty repository. Cloned by the init container, which needs egress -
# the same egress install-konveyor already needs to pull images.
SOURCE_REPO="${SOURCE_REPO:-https://github.com/konveyor/tackle-testapp-public.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-main}"
GIT_SERVER_NAME="${GIT_SERVER_NAME:-git-remote}"
# Has git, but not `git daemon`: Alpine packages the daemon separately, so
# the serving container installs it on start. Any image that ships git-daemon
# can replace this and drop that step.
GIT_IMAGE="${GIT_IMAGE:-docker.io/alpine/git:latest}"
REPO_NAME="${REPO_NAME:-testapp}"

GIT_URL="git://${GIT_SERVER_NAME}.${NAMESPACE}.svc.cluster.local/${REPO_NAME}.git"

echo "=== Deploying the in-cluster git remote"
# emptyDir, not a PVC: the content is re-mirrored on every pod start and the
# cluster is thrown away at the end of the job, so persistence would only buy
# a slower start and a volume to clean up.
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${GIT_SERVER_NAME}
  labels:
    app: ${GIT_SERVER_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${GIT_SERVER_NAME}
  template:
    metadata:
      labels:
        app: ${GIT_SERVER_NAME}
    spec:
      initContainers:
        - name: seed
          image: ${GIT_IMAGE}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eux
              # --mirror gives a bare repository with every ref, so the
              # branch the application names resolves without a checkout.
              git clone --mirror "${SOURCE_REPO}" "/srv/git/${REPO_NAME}.git"
              cd "/srv/git/${REPO_NAME}.git"
              # A mirror is configured to overwrite local refs from its
              # origin on fetch. Nothing fetches here, and leaving it set
              # would make the remote look like it tracks upstream when it
              # is now the authority for what the run pushes.
              git config --unset remote.origin.mirror || true
              git remote remove origin || true
              # --enable=receive-pack on the daemon turns anonymous push on
              # for every repository it serves; this says the same thing
              # per-repository, so the remote keeps accepting pushes if
              # anyone ever drops the daemon flag.
              git config daemon.receivepack true
          volumeMounts:
            - name: repos
              mountPath: /srv/git
      containers:
        - name: daemon
          image: ${GIT_IMAGE}
          # --enable=receive-pack is the whole point: without it the daemon
          # serves reads and the write pre-flight fails exactly as GitHub's
          # does, which would leave this fixture no better than the one it
          # replaces.
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eux
              # The image's git has no daemon subcommand; it is the separate
              # git-daemon package on Alpine. Same egress the seed clone needs.
              apk add --no-cache git-daemon
              exec git daemon \
                --verbose \
                --reuseaddr \
                --export-all \
                --enable=receive-pack \
                --base-path=/srv/git \
                --listen=0.0.0.0 \
                --port=9418 \
                /srv/git
          ports:
            - containerPort: 9418
              name: git
          readinessProbe:
            tcpSocket:
              port: 9418
            initialDelaySeconds: 2
            periodSeconds: 3
          volumeMounts:
            - name: repos
              mountPath: /srv/git
      volumes:
        - name: repos
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${GIT_SERVER_NAME}
spec:
  selector:
    app: ${GIT_SERVER_NAME}
  ports:
    - name: git
      port: 9418
      targetPort: 9418
YAML

echo "=== Waiting for the git remote"
if ! kubectl -n "${NAMESPACE}" rollout status "deployment/${GIT_SERVER_NAME}" --timeout=300s; then
  # The clone is the part that fails in practice - no egress, or the source
  # repository moved - and it happens in an init container, whose logs the
  # rollout failure does not show.
  kubectl -n "${NAMESPACE}" logs "deployment/${GIT_SERVER_NAME}" -c seed --tail=100 || true
  kubectl -n "${NAMESPACE}" describe "deployment/${GIT_SERVER_NAME}" || true
  exit 1
fi

echo "=== Pointing ${APP_NAME} at ${GIT_URL}"
# Same in-cluster reach as ../seed-application.sh: the Hub Service is found
# by the label the operator sets, so this needs no ingress and no route.
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

CODE=$(curl -sk -o /tmp/hub-apps.json -w '%{http_code}' "${HUB}/applications")
if [ "${CODE}" != "200" ]; then
  echo "Hub returned HTTP ${CODE} listing applications" >&2
  exit 1
fi

# Create or repoint, rather than create-if-absent: install-konveyor's
# seed_application may already have made this application against a public
# URL, and an existing application with the wrong repository is the case
# that breaks runs - exactly the one a create-only script skips over.
APP_ID=$(APP_NAME="${APP_NAME}" python3 -c '
import json, os, sys
name = os.environ["APP_NAME"]
apps = json.load(open("/tmp/hub-apps.json"))
match = next((a for a in apps if a.get("name") == name), None)
sys.stdout.write(str(match["id"]) if match else "")
')

APP_JSON=$(APP_NAME="${APP_NAME}" GIT_URL="${GIT_URL}" BRANCH="${SOURCE_BRANCH}" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "name": os.environ["APP_NAME"],
    "repository": {"kind": "git",
                   "url": os.environ["GIT_URL"],
                   "branch": os.environ["BRANCH"]},
}))
')

if [ -n "${APP_ID}" ]; then
  # PUT replaces the resource, so the id has to travel with the body.
  BODY=$(APP_ID="${APP_ID}" APP_JSON="${APP_JSON}" python3 -c '
import json, os, sys
app = json.loads(os.environ["APP_JSON"])
app["id"] = int(os.environ["APP_ID"])
sys.stdout.write(json.dumps(app))
')
  CODE=$(curl -sk -o /tmp/hub-put.json -w '%{http_code}' -X PUT \
    "${HUB}/applications/${APP_ID}" -H "Content-Type: application/json" -d "${BODY}")
  EXPECTED="204"
else
  CODE=$(curl -sk -o /tmp/hub-put.json -w '%{http_code}' -X POST \
    "${HUB}/applications" -H "Content-Type: application/json" -d "${APP_JSON}")
  EXPECTED="201"
fi

case "${CODE}" in
  200|201|204) echo "  ${APP_NAME} -> ${GIT_URL}" ;;
  *)
    echo "Pointing ${APP_NAME} at ${GIT_URL} failed (HTTP ${CODE}, wanted ${EXPECTED}):" >&2
    cat /tmp/hub-put.json >&2
    exit 1
    ;;
esac

echo "=== Git remote ready"
