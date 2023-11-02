#!/bin/bash
set -e
set -x

# Figure out where we are being run from.
# This relies on script being run from:
#  - ${PROJECT_ROOT}/hack/install-tackle.sh
#  - ${PROJECT_ROOT}/bin/install-tackle.sh
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__root="$(cd "$(dirname "${__dir}")" && pwd)"
__repo="$(basename "${__root}")"
__bin_dir="${__root}/bin"
__os="$(uname -s | tr '[:upper:]' '[:lower:]')"
__arch="$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"

# Update PATH for execution of this script
export PATH="${__bin_dir}:${PATH}"

# Inputs via environment variables
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-}"
MINIKUBE_CONTAINER_RUNTIME="${MINIKUBE_CONTAINER_RUNTIME:-}"
MINIKUBE_KUBERNETES_VERSION="${MINIKUBE_KUBERNETES_VERSION:-}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-}"
MINIKUBE_CNI="${MINIKUBE_CNI:-}"
OLM="${OLM:-true}"

# Check pre-reqs
# May want to leave this for the user to install
if ! command -v minikube >/dev/null 2>&1; then
  echo "Please install minikube"
  exit 1
fi

# Start minikube if not already started
if ! minikube status; then
  ARGS=""
  [ -z "${MINIKUBE_DRIVER}" ] || \
    ARGS+=" --driver=${MINIKUBE_DRIVER}"
  [ -z "${MINIKUBE_CONTAINER_RUNTIME}" ] || \
    ARGS+=" --container-runtime=${MINIKUBE_CONTAINER_RUNTIME}"
  [ -z "${MINIKUBE_KUBERNETES_VERSION}" ] || \
    ARGS+=" --kubernetes-version=${MINIKUBE_KUBERNETES_VERSION}"
  [ -z "${MINIKUBE_CPUS}" ] || \
    ARGS+=" --cpus=${MINIKUBE_CPUS}"
  [ -z "${MINIKUBE_MEMORY}" ] || \
    ARGS+=" --memory=${MINIKUBE_MEMORY}"
  [ -z "${MINIKUBE_CNI}" ] || \
    ARGS+=" --cni=${MINIKUBE_CNI}"
  set -x
  minikube start ${ARGS}
fi

# Enable ingress
minikube addons enable ingress

if [ "${OLM}" = "true" ]; then
  curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.26.0/install.sh | bash -s v0.26.0
fi
