export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SIMULATOR ?= iPhone 17

.PHONY: help project osm data test test-python test-swift sim device spike-sim spike-device clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-14s %s\n", $$1, $$2}'

project: ## Generate WatPath.xcodeproj from project.yml
	xcodegen generate --quiet

osm: ## Re-import building outlines from OpenStreetMap (needs network)
	python3 tools/osm_import/import_osm.py

data: ## Compile data/ into build/CampusBundle
	python3 tools/compiler/compile.py

test: test-python test-swift ## Run all tests

test-python: ## Run tool tests
	uv run --no-project --with pytest pytest -q

test-swift: ## Run WatPathKit tests
	swift test --package-path Packages/WatPathKit

sim: project data ## Build and launch in the Simulator
	tools/run.sh simulator "$(SIMULATOR)"

device: project data ## Build, install and launch on the connected iPhone
	tools/run.sh device

spike-sim: project data ## Simulator, running the scripted camera spike
	tools/run.sh simulator "$(SIMULATOR)" -- -autoSpike

spike-device: project data ## iPhone, running the scripted camera spike
	tools/run.sh device -- -autoSpike

clean: ## Remove build outputs
	rm -rf build/DerivedData build/CampusBundle
