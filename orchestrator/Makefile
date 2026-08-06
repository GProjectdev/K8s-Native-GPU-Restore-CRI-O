# Restore orchestrator build helpers.
IMG ?= docker.io/jeongseungjun/gpu-cr-restore-orchestrator:latest
CONTROLLER_GEN ?= go run sigs.k8s.io/controller-tools/cmd/controller-gen@v0.15.0

.PHONY: tidy generate manifests build docker-build docker-push
tidy:
	go mod tidy
generate: ## regenerate zz_generated.deepcopy.go from the +kubebuilder markers
	$(CONTROLLER_GEN) object:headerFile="" paths="./api/..."
manifests: ## regenerate the CRD yaml from the +kubebuilder markers
	$(CONTROLLER_GEN) crd paths="./api/..." output:crd:dir="./config/crd"
build: tidy
	go build ./...
docker-build:
	docker build -t $(IMG) -f Dockerfile .
docker-push:
	docker push $(IMG)
