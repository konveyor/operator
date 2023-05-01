# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= 99.0.0

# CONTAINER_RUNTIME defines the container runtime used in the Makefile to allow usage
# with docker or podman
CONTAINER_RUNTIME ?= docker

# TARGET_ARCH is the architecture of the image to be built
# Note, that even developers running on arm64 Macs will likely want to set
# this to amd64 when building local images to deploy into remote clusters
TARGET_ARCH ?= amd64

# CHANNELS define the bundle channels used in the bundle.
CHANNELS = "development"
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
DEFAULT_CHANNEL = "development"
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# konveyor.io/tackle-operator-bundle:$VERSION and konveyor.io/tackle-operator-catalog:$VERSION.
IMAGE_TAG_BASE ?= quay.io/konveyor/tackle2-operator

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# BUNDLE_GEN_FLAGS are the flags passed to the operator-sdk generate bundle command
BUNDLE_GEN_FLAGS ?= -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

# USE_IMAGE_DIGESTS defines if images are resolved via tags or digests
# You can enable this value if you would like to use SHA Based Digests
# To enable set flag to true
USE_IMAGE_DIGESTS ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
	BUNDLE_GEN_FLAGS += --use-image-digests
endif

# Image URL to use all building/pushing image targets
IMG ?= quay.io/konveyor/tackle2-operator:latest

.PHONY: all
all: docker-build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Build

.PHONY: run
run: ansible-operator ## Run against the configured Kubernetes cluster in ~/.kube/config
	ANSIBLE_ROLES_PATH="$(ANSIBLE_ROLES_PATH):$(shell pwd)/roles" $(ANSIBLE_OPERATOR) run

TARGET_PLATFORMS ?= linux/${TARGET_ARCH}
.PHONY: docker-build
docker-build: ## Build docker image with the manager.
ifeq ($(CONTAINER_RUNTIME), podman)
	$(CONTAINER_RUNTIME) build --arch ${TARGET_ARCH} -t ${IMG} .
else
	$(CONTAINER_RUNTIME) build --platform ${TARGET_PLATFORMS} -t ${IMG} .
endif

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_RUNTIME) push ${IMG}

##@ Deployment

.PHONY: install
install: kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

.PHONY: deploy
deploy: kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

GIT_REV:=$(shell git rev-parse --short HEAD)
## Build current branch operator image, bundle image, push and install via OLM
.PHONY: deploy-olm
deploy-olm: THIS_OPERATOR_IMAGE?=ttl.sh/konveyor-operator-$(GIT_REV):1h # Set target specific variable
deploy-olm: THIS_BUNDLE_IMAGE?=ttl.sh/konveyor-operator-bundle-$(GIT_REV):1h # Set target specific variable
deploy-olm: NAMESPACE?=konveyor-tackle
deploy-olm: DEPLOY_TMP:=$(shell mktemp -d)/ # Set target specific variable
deploy-olm: operator-sdk ## Build current branch operator image, bundle image, push and install via OLM
	kubectl auth can-i create ns --all-namespaces # Check if logged in
	kubectl create namespace $(NAMESPACE) || true
	$(OPERATOR_SDK) cleanup konveyor-operator --namespace $(NAMESPACE)
	@echo "DEPLOY_TMP: $(DEPLOY_TMP)"
	# build and push operator and bundle image
	# use $(OPERATOR_SDK) to install bundle to authenticated cluster
	cp -r . $(DEPLOY_TMP) && cd $(DEPLOY_TMP) && \
	IMG=$(THIS_OPERATOR_IMAGE) BUNDLE_IMG=$(THIS_BUNDLE_IMAGE) \
		make docker-build docker-push bundle bundle-build bundle-push; \
	rm -rf $(DEPLOY_TMP)
	$(OPERATOR_SDK) run bundle $(THIS_BUNDLE_IMAGE) --namespace $(NAMESPACE)

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default | kubectl delete -f -

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/')

.PHONY: kustomize
KUSTOMIZE = $(shell pwd)/bin/kustomize
KUSTOMIZE_ARCH=$(ARCH)
ifeq ($(OS),darwin)
# Kustomize does not provide a Darwin/arm64 binary for v3.8.7
	KUSTOMIZE_ARCH="amd64"
endif
kustomize: ## Download kustomize locally if necessary.
ifeq (,$(wildcard $(KUSTOMIZE)))
ifeq (,$(shell which kustomize 2>/dev/null))
	@{ \
	set -e &&\
	echo "$(KUSTOMIZE_ARCH)" &&\
	mkdir -p $(dir $(KUSTOMIZE)) &&\
	echo https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v3.8.7/kustomize_v3.8.7_$(OS)_$(KUSTOMIZE_ARCH).tar.gz &&\
	curl -sSLo - https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v3.8.7/kustomize_v3.8.7_$(OS)_$(KUSTOMIZE_ARCH).tar.gz | \
	tar xzf - -C bin/ ;\
	}
else
KUSTOMIZE = $(shell which kustomize)
endif
endif

.PHONY: ansible-operator
ANSIBLE_OPERATOR = $(shell pwd)/bin/ansible-operator
ansible-operator: ## Download ansible-operator locally if necessary, preferring the $(pwd)/bin path over global if both exist.
ifeq (,$(wildcard $(ANSIBLE_OPERATOR)))
ifeq (,$(shell which ansible-operator 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(ANSIBLE_OPERATOR)) ;\
	curl -sSLo $(ANSIBLE_OPERATOR) https://github.com/operator-framework/operator-sdk/releases/download/v1.22.0/ansible-operator_$(OS)_$(ARCH) ;\
	chmod +x $(ANSIBLE_OPERATOR) ;\
	}
else
ANSIBLE_OPERATOR = $(shell which ansible-operator)
endif
endif

OPERATOR_SDK = $(shell pwd)/bin/operator-sdk
.PHONY: operator-sdk
operator-sdk: $(OPERATOR_SDK)

$(OPERATOR_SDK):
	mkdir -p $(dir $(OPERATOR_SDK)) && \
	curl -Lo $(OPERATOR_SDK) https://github.com/operator-framework/operator-sdk/releases/download/v1.28.1/operator-sdk_$(shell go env GOOS)_$(shell go env GOARCH) && \
	chmod +x $(OPERATOR_SDK);

.PHONY: bundle
bundle: kustomize operator-sdk ## Generate bundle manifests and metadata, then validate generated files.
	$(OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle -q --overwrite --extra-service-accounts tackle-hub,tackle-ui --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	$(OPERATOR_SDK) bundle validate ./bundle

.PHONY: bundle-build
bundle-build: ## Build the bundle image.
ifeq ($(CONTAINER_RUNTIME), podman)
	$(CONTAINER_RUNTIME) build --arch ${TARGET_ARCH} -f bundle.Dockerfile -t $(BUNDLE_IMG) .
else
	$(CONTAINER_RUNTIME) build --platform ${TARGET_PLATFORMS} -f bundle.Dockerfile -t $(BUNDLE_IMG) .
endif

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: opm
OPM = ./bin/opm
opm: ## Download opm locally if necessary.
ifeq (,$(wildcard $(OPM)))
ifeq (,$(shell which opm 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPM)) ;\
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v1.23.0/$(OS)-$(ARCH)-opm ;\
	chmod +x $(OPM) ;\
	}
else
OPM = $(shell which opm)
endif
endif

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:v$(VERSION)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool $(CONTAINER_RUNTIME) --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

# Push the catalog image.
.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

.PHONY: start-minikube
start-minikube:
	export PATH=$(shell pwd)/bin:$$PATH; $(shell pwd)/hack/start-minikube.sh

.PHONY: install-tackle
install-tackle:
	export PATH=$(shell pwd)/bin:$$PATH; $(shell pwd)/hack/install-tackle.sh
