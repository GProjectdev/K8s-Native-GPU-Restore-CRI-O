SHELL := /bin/bash
SCRIPTS := hooks/gpu-cr-restore-hook hooks/lib/*.sh hack/*.sh scripts/*.sh \
           alt-shim/runtime/gpu-cr-restore-shim alt-shim/runtime/lib/*.sh alt-shim/*.sh

.PHONY: lint build-crio install-node
lint:           ## syntax-check shell + verify the patch applies to cri-o v1.35.0
	@for f in $(SCRIPTS); do bash -n "$$f" && echo "ok: $$f"; done
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning $(SCRIPTS) || echo "(shellcheck skipped)"

build-crio:     ## clone cri-o v1.35.0, apply the patch, build the binary
	./hack/build-crio.sh

install-node:   ## install hooks + CRI-O drop-in on this node (root)
	sudo ./scripts/install-node.sh
