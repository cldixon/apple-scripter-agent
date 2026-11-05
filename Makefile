# Common tasks. Run `make help` for the list.
PROJECT      := AutomationAgent.xcodeproj
SCHEME       := AutomationAgent
DERIVED_DATA := build/DerivedData
APP          := $(DERIVED_DATA)/Build/Products/Debug/AutomationAgent.app
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA)

.PHONY: help bootstrap check-xcode project build build-unsigned test lint format run verify release release-local clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

bootstrap: check-xcode ## Install the command-line tools this repo uses (Homebrew)
	brew install xcodegen swiftlint
	@test -f Config/Local.xcconfig || { cp Config/Local.xcconfig.example Config/Local.xcconfig; \
		echo "Created Config/Local.xcconfig: set DEVELOPMENT_TEAM in it before building."; }

check-xcode: ## Fail with the fix if xcode-select points at the Command Line Tools
	scripts/check-xcode.sh

project: ## Generate AutomationAgent.xcodeproj from project.yml
	xcodegen generate

build: check-xcode project ## Build the app, signed with the team in Config/Local.xcconfig
	$(XCODEBUILD) build

build-unsigned: project ## Build without code signing (what CI does)
	$(XCODEBUILD) CODE_SIGNING_ALLOWED=NO build

test: ## Run the Shared package's unit tests
	swift test --package-path Shared

lint: ## Run SwiftLint
	swiftlint lint --strict

format: ## Auto-fix what SwiftLint can
	swiftlint lint --fix

verify: ## Check the built app's bundle layout
	scripts/verify-bundle.sh $(APP)

run: build verify ## Build, then launch the app
	open $(APP)

release: check-xcode ## Signed, notarized, stapled DMG in build/release (docs/RELEASING.md)
	scripts/release.sh

release-local: check-xcode ## Signed DMG without notarizing, for local testing
	scripts/release.sh --skip-notarize

clean: ## Remove build output and the generated project
	rm -rf build $(PROJECT) Shared/.build
