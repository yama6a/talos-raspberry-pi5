# A thin dispatcher over lib/. Holds NO logic, versions or values: every target just runs the script it
# names, so `make build` and `bash lib/build.sh` are identical. `make help` lists everything.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Image
.PHONY: resolve
resolve: ## Resolve pkgs + kernel from the pinned Talos release into .cache/build-inputs.json (network only, ~10s).
	bash lib/resolve_inputs.sh

.PHONY: build
build: resolve ## Build the kernel, overlay, installer and raw disk image. Long: ~40 min native arm64.
	bash lib/build.sh

.PHONY: validate
validate: ## Check the built image offline: partition layout, Pi 5 boot bits, kernel label, baked extensions.
	bash lib/validate.sh

.PHONY: publish
publish: ## Push the installer to GHCR and stage the release assets. Needs GHCR_TOKEN (or CI's GITHUB_TOKEN).
	bash lib/publish.sh

.PHONY: release
release: ## Create the GitHub release from the staged assets. Run after publish; needs gh.
	bash lib/release.sh

##@ Housekeeping
.PHONY: clean
clean: ## Remove the current build's scratch dir, keeping other cached builds.
	bash lib/clean.sh

.PHONY: distclean
distclean: ## Remove .cache entirely (every cached build; tens of GB).
	bash lib/clean.sh --all
