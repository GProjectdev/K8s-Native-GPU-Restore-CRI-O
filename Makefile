# Convenience targets for the gpu-cr-restore runtime handler.
SHELL := /bin/bash
SCRIPTS := runtime/gpu-cr-restore-shim runtime/lib/*.sh scripts/*.sh

.PHONY: lint install uninstall
lint:        ## syntax-check all shell sources (+ shellcheck if available)
	@for f in $(SCRIPTS); do bash -n "$$f" && echo "ok: $$f"; done
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning $(SCRIPTS) || echo "(shellcheck not installed; skipped)"

install:     ## install the runtime handler on this node (root)
	sudo ./scripts/install-crio-runtime.sh

uninstall:   ## remove the runtime handler (root)
	sudo ./scripts/uninstall-crio-runtime.sh
