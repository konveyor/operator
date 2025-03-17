#!/bin/bash
set -e
set -x

# Inputs via environment variables
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-}"
MINIKUBE_CONTAINER_RUNTIME="${MINIKUBE_CONTAINER_RUNTIME:-}"
MINIKUBE_KUBERNETES_VERSION="${MINIKUBE_KUBERNETES_VERSION:-}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-}"
MINIKUBE_CNI="${MINIKUBE_CNI:-}"
LOCAL_MAVEN_CACHE="${LOCAL_MAVEN_CACHE:-}"
MOUNTED_MAVEN_CACHE="${MOUNTED_MAVEN_CACHE:-/data/m2}"

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
if [[ -n "$LOCAL_MAVEN_CACHE" ]]; then
  minikube mount ${LOCAL_MAVEN_CACHE}:${MOUNTED_MAVEN_CACHE}
fi
