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
CHANNELS ?= "development"
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
comma := ,
space :=
space +=
DEFAULT_CHANNEL ?= $(word 1,$(subst $(comma), $(space), $(CHANNELS)))
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

IMAGE_ORG ?= quay.io/konveyor

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# konveyor.io/tackle-operator-bundle:$VERSION and konveyor.io/tackle-operator-catalog:$VERSION.
IMAGE_TAG_BASE ?= $(IMAGE_ORG)/tackle2-operator

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# BUNDLE_GEN_FLAGS are the flags passed to the operator-sdk generate bundle command
BUNDLE_GEN_FLAGS ?= -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

HELM_RELEASE ?= my-konveyor-release
NAMESPACE ?= konveyor-tackle

# USE_IMAGE_DIGESTS defines if images are resolved via tags or digests
# You can enable this value if you would like to use SHA Based Digests
# To enable set flag to true
USE_IMAGE_DIGESTS ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
	BUNDLE_GEN_FLAGS += --use-image-digests
endif

# Image URL to use all building/pushing image targets
IMG ?= $(IMAGE_ORG)/tackle2-operator:latest

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
ANSIBLE_ROLES_PATH?="$(shell pwd)/roles"
run: ansible-operator ## Run against the configured Kubernetes cluster in ~/.kube/config
	$(ANSIBLE_OPERATOR) run

TARGET_PLATFORMS ?= linux/${TARGET_ARCH}
CONTAINER_BUILDARGS ?= --build-arg OPERATOR_SDK_VERSION=v1.28.1
.PHONY: docker-build
docker-build: ## Build docker image with the manager.
ifeq ($(CONTAINER_RUNTIME), podman)
	$(CONTAINER_RUNTIME) build --arch ${TARGET_ARCH} -t ${IMG} .
else
	$(CONTAINER_RUNTIME) build --platform ${TARGET_PLATFORMS} -t ${IMG} .
endif

# PLATFORMS defines the target platforms for  the manager image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image for your registry (i.e. if you do not inform a valid value via IMG=<myregistry/image:<tag>> than the export will fail)
# To properly provided solutions that supports more than one platform you should use this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- docker buildx create --name project-v3-builder
	docker buildx use project-v3-builder
	- docker buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross
	- docker buildx rm project-v3-builder
	rm Dockerfile.cross

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_RUNTIME) push ${IMG}

##@ Deployment

# HELM_OPTS="--set images.operator=quay.io/mine/tackle2-operator:foobar"
.PHONY: install
install: helm ## Install operator directly into cluster specified in ~/.kube/config
	kubectl auth can-i create ns --all-namespaces # Check if logged in
	kubectl create namespace $(NAMESPACE) || true
	$(HELM) install $(HELM_RELEASE) ./helm --namespace $(NAMESPACE) $(HELM_OPTS)

.PHONY: uninstall
uninstall: helm ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(HELM) uninstall --namespace $(NAMESPACE) $(HELM_RELEASE) 

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')

.PHONY: helm
HELM = $(shell pwd)/bin/helm
HELM_VERSION = v3.13.1
helm: ## Download helm locally if necessary.
ifeq (,$(wildcard $(HELM)))
ifeq (,$(shell which helm 2>/dev/null))
	@{ \
	set -e &&\
	mkdir -p $(dir $(HELM)) &&\
	echo https://github.com/helm/helm/releases/download/$(HELM_VERSION)/helm-$(HELM_VERSION)-$(OS)-$(ARCH).tar.gz &&\
	curl -sSLo - https://github.com/helm/helm/releases/download/$(HELM_VERSION)/helm-$(HELM_VERSION)-$(OS)-$(ARCH).tar.gz | \
	tar xzf - -C $(dir $(HELM)) ;\
	}
else
HELM = $(shell which helm)
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
	curl -sSLo $(ANSIBLE_OPERATOR) https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/ansible-operator_$(OS)_$(ARCH) ;\
	chmod +x $(ANSIBLE_OPERATOR) ;\
	}
else
ANSIBLE_OPERATOR = $(shell which ansible-operator)
endif
endif

OPERATOR_SDK = $(shell pwd)/bin/operator-sdk
OPERATOR_SDK_VERSION ?= v1.28.1
.PHONY: operator-sdk
operator-sdk:
ifeq (,$(wildcard $(OPERATOR_SDK)))
ifeq (,$(shell which operator-sdk 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPERATOR_SDK)) ;\
	curl -Lo $(OPERATOR_SDK) https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$(shell go env GOOS)_$(shell go env GOARCH) ;\
	chmod +x $(OPERATOR_SDK) ;\
	}
else
OPERATOR_SDK = $(shell which operator-sdk)
endif
endif

# HELM_OPTS="--set images.operator=quay.io/mine/tackle2-operator:foobar"
# putting it last allows the operator image to be overridden
.PHONY: bundle
bundle: helm operator-sdk ## Generate bundle manifests and metadata, then validate generated files.
	$(HELM) template --set images.operator=${IMG} --set version=$(VERSION) --set olm=true $(HELM_OPTS) ./helm | $(OPERATOR_SDK) generate bundle --extra-service-accounts tackle-hub,tackle-ui $(BUNDLE_GEN_FLAGS)
	$(OPERATOR_SDK) bundle validate ./bundle

.PHONY: bundle-sync-check
bundle-sync-check:
	git diff --exit-code -I'^    createdAt: ' bundle

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
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v1.30.0/$(OS)-$(ARCH)-opm ;\
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
	$(shell pwd)/hack/start-minikube.sh

.PHONY: install-tackle
install-tackle:
	$(shell pwd)/hack/install-tackle.sh

.PHONY: install-konveyor
install-konveyor:
	$(shell pwd)/hack/install-konveyor.sh

YQ = $(shell pwd)/bin/yq
.PHONY: yq
yq:
ifeq (,$(wildcard $(YQ)))
ifeq (,$(shell which yq 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(YQ)) ;\
	curl -L https://github.com/mikefarah/yq/releases/download/v4.13.5/yq_$(OS)_$(ARCH) -o $(YQ) ;\
	chmod +x $(YQ) ;\
	}
else
YQ = $(shell which yq)
endif
endif

OPENSHIFT_CLIENT = $(shell pwd)/bin/oc
.PHONY: openshift-client
openshift-client:
ifeq (,$(wildcard $(OPENSHIFT_CLIENT)))
ifeq (,$(shell which oc 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPENSHIFT_CLIENT)) ;\
	curl -L https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-$(subst darwin,mac,$(OS))-$(ARCH).tar.gz -o $(dir $(OPENSHIFT_CLIENT))openshift-client.tar.gz ;\
	tar zxf $(dir $(OPENSHIFT_CLIENT))openshift-client.tar.gz -C $(dir $(OPENSHIFT_CLIENT)) ;\
	rm $(dir $(OPENSHIFT_CLIENT))openshift-client.tar.gz ;\
	}
else
OPENSHIFT_CLIENT = $(shell which oc)
endif
endif
