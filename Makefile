IMG ?= linode/linode-cloud-controller-manager:canary
RELEASE_DIR ?= release
PLATFORM ?= linux/amd64
LINODE_FIREWALL_ENABLED ?= true
LINODE_REGION ?= us-lax
KUBECONFIG_PATH ?= $(CURDIR)/test-cluster-kubeconfig.yaml

# Use CACHE_BIN for tools that cannot use devbox and LOCALBIN for tools that can use either method
CACHE_BIN ?= $(CURDIR)/bin
LOCALBIN ?= $(CACHE_BIN)

DEVBOX_BIN ?= $(DEVBOX_PACKAGES_DIR)/bin

#####################################################################
# Dev Setup
#####################################################################
CLUSTER_NAME         ?= ccm-$(shell git rev-parse --short HEAD)
K8S_VERSION          ?= "v1.29.1"
CAPI_VERSION         ?= "v1.6.3"
HELM_VERSION         ?= "v0.2.1"
CAPL_VERSION         ?= "v0.7.1"
CONTROLPLANE_NODES   ?= 1
WORKER_NODES         ?= 1

# if the $DEVBOX_PACKAGES_DIR env variable exists that means we are within a devbox shell and can safely
# use devbox's bin for our tools
ifdef DEVBOX_PACKAGES_DIR
	LOCALBIN = $(DEVBOX_BIN)
endif

export PATH := $(CACHE_BIN):$(PATH)
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

export GO111MODULE=on

.PHONY: all
all: build

.PHONY: clean
clean:
	@go clean .
	@rm -rf ./.tmp
	@rm -rf dist/*
	@rm -rf $(RELEASE_DIR)
	@rm -rf $(LOCALBIN)

.PHONY: codegen
codegen:
	go generate ./...

.PHONY: vet
vet: fmt
	go vet ./...

.PHONY: lint
lint:
	docker run --rm -v "$(shell pwd):/var/work:ro" -w /var/work \
		golangci/golangci-lint:v1.57.2 golangci-lint run -v --timeout=5m
	docker run --rm -v "$(shell pwd):/var/work:ro" -w /var/work/e2e \
		golangci/golangci-lint:v1.57.2 golangci-lint run -v --timeout=5m

.PHONY: fmt
fmt:
	go fmt ./...

.PHONY: test
# we say code is not worth testing unless it's formatted
test: fmt codegen
	go test -v -cover -coverprofile ./coverage.out ./cloud/... $(TEST_ARGS)

.PHONY: build-linux
build-linux: codegen
	echo "cross compiling linode-cloud-controller-manager for linux/amd64" && \
		GOOS=linux GOARCH=amd64 \
		CGO_ENABLED=0 \
		go build -o dist/linode-cloud-controller-manager-linux-amd64 .

.PHONY: build
build: codegen
	echo "compiling linode-cloud-controller-manager" && \
		CGO_ENABLED=0 \
		go build -o dist/linode-cloud-controller-manager .

.PHONY: release
release:
	mkdir -p $(RELEASE_DIR)
	sed -e 's/appVersion: "latest"/appVersion: "$(IMAGE_VERSION)"/g' ./deploy/chart/Chart.yaml
	tar -czvf ./$(RELEASE_DIR)/helm-chart-$(IMAGE_VERSION).tgz -C ./deploy/chart .

.PHONY: imgname
# print the Docker image name that will be used
# useful for subsequently defining it on the shell
imgname:
	echo IMG=${IMG}

.PHONY: docker-build
# we cross compile the binary for linux, then build a container
docker-build: build-linux
	DOCKER_BUILDKIT=1 docker build --platform=$(PLATFORM) --tag ${IMG} .

.PHONY: docker-push
# must run the docker build before pushing the image
docker-push:
	docker push ${IMG}

.PHONY: docker-setup
docker-setup: docker-build docker-push

.PHONY: run
# run the ccm locally, really only makes sense on linux anyway
run: build
	dist/linode-cloud-controller-manager \
		--logtostderr=true \
		--stderrthreshold=INFO \
		--kubeconfig=${KUBECONFIG}

.PHONY: run-debug
# run the ccm locally, really only makes sense on linux anyway
run-debug: build
	dist/linode-cloud-controller-manager \
		--logtostderr=true \
		--stderrthreshold=INFO \
		--kubeconfig=${KUBECONFIG} \
		--linodego-debug

#####################################################################
# E2E Test Setup
#####################################################################

.PHONY: mgmt-and-capl-cluster
mgmt-and-capl-cluster: docker-setup mgmt-cluster capl-cluster

.PHONY: capl-cluster
capl-cluster: generate-capl-cluster-manifests create-capl-cluster patch-linode-ccm

.PHONY: generate-capl-cluster-manifests
generate-capl-cluster-manifests:
	# Create the CAPL cluster manifests without any CSI driver stuff
	LINODE_FIREWALL_ENABLED=$(LINODE_FIREWALL_ENABLED) clusterctl generate cluster $(CLUSTER_NAME) \
		--kubernetes-version $(K8S_VERSION) \
		--infrastructure linode-linode:$(CAPL_VERSION) \
		--control-plane-machine-count $(CONTROLPLANE_NODES) --worker-machine-count $(WORKER_NODES) > capl-cluster-manifests.yaml

.PHONY: create-capl-cluster
create-capl-cluster:
	# Create a CAPL cluster with updated CCM and wait for it to be ready
	kubectl apply -f capl-cluster-manifests.yaml
	kubectl wait --for=condition=ControlPlaneReady cluster/$(CLUSTER_NAME) --timeout=600s || (kubectl get cluster -o yaml; kubectl get linodecluster -o yaml; kubectl get linodemachines -o yaml)
	kubectl wait --for=condition=NodeHealthy=true machines -l cluster.x-k8s.io/cluster-name=$(CLUSTER_NAME) --timeout=900s
	clusterctl get kubeconfig $(CLUSTER_NAME) > $(KUBECONFIG_PATH)
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl wait --for=condition=Ready nodes --all --timeout=600s
	# Remove all taints so that pods can be scheduled anywhere (without this, some tests fail)
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl taint nodes -l node-role.kubernetes.io/control-plane node-role.kubernetes.io/control-plane-

.PHONY: patch-linode-ccm
patch-linode-ccm:
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl patch -n kube-system daemonset ccm-linode --type='json' -p="[{'op': 'replace', 'path': '/spec/template/spec/containers/0/image', 'value': '${IMG}'}]"
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl rollout status -n kube-system daemonset/ccm-linode --timeout=600s

.PHONY: mgmt-cluster
mgmt-cluster:
	# Create a mgmt cluster
	ctlptl apply -f e2e/setup/ctlptl-config.yaml
	clusterctl init \
		--wait-providers \
		--wait-provider-timeout 600 \
		--core cluster-api:$(CAPI_VERSION) \
		--addon helm:$(HELM_VERSION) \
		--infrastructure linode-linode:$(CAPL_VERSION)

.PHONY: cleanup-cluster
cleanup-cluster:
	kubectl delete cluster --all
	kubectl delete linodefirewalls --all
	kubectl delete lvpc --all
	kind delete cluster -n caplccm

.PHONY: e2e-test
e2e-test:
	$(MAKE) -C e2e test LINODE_API_TOKEN=$(LINODE_TOKEN) SUITE_ARGS="--region=$(LINODE_REGION) --use-existing --timeout=5m --kubeconfig=$(KUBECONFIG_PATH) --image=$(IMG) --linode-url https://api.linode.com/"

#####################################################################
# OS / ARCH
#####################################################################

# Set the host's OS. Only linux and darwin supported for now
HOSTOS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ifeq ($(filter darwin linux,$(HOSTOS)),)
$(error build only supported on linux and darwin host currently)
endif
ARCH=$(shell uname -m)
ARCH_SHORT=$(ARCH)
ifeq ($(ARCH_SHORT),x86_64)
ARCH_SHORT := amd64
else ifeq ($(ARCH_SHORT),aarch64)
ARCH_SHORT := arm64
endif

HELM         ?= $(LOCALBIN)/helm
HELM_VERSION ?= v3.9.1

.PHONY: helm
helm: $(HELM) ## Download helm locally if necessary
$(HELM): $(LOCALBIN)
	@curl -fsSL https://get.helm.sh/helm-$(HELM_VERSION)-$(HOSTOS)-$(ARCH_SHORT).tar.gz | tar -xz
	@mv $(HOSTOS)-$(ARCH_SHORT)/helm $(HELM)
	@rm -rf helm.tgz $(HOSTOS)-$(ARCH_SHORT)

.PHONY: helm-lint
helm-lint: helm
#Verify lint works when region and apiToken are passed, and when it is passed as reference.
	@$(HELM) lint deploy/chart --set apiToken="apiToken",region="us-east"
	@$(HELM) lint deploy/chart --set secretRef.apiTokenRef="apiToken",secretRef.name="api",secretRef.regionRef="us-east"

.PHONY: helm-template
helm-template: helm
#Verify template works when region and apiToken are passed, and when it is passed as reference.
	@$(HELM) template foo deploy/chart --set apiToken="apiToken",region="us-east" > /dev/null
	@$(HELM) template foo deploy/chart --set secretRef.apiTokenRef="apiToken",secretRef.name="api",secretRef.regionRef="us-east" > /dev/null
