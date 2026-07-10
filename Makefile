.PHONY: generate test test-ios test-xcode test-unit test-macos-unit test-integration test-e2e test-flow-runtime-ui test-all build-macos build-reference-app install-reference-app clean help coverage coverage-html coverage-json coverage-summary install-deps check-xcodegen

XCODEGEN_STAMP := .xcodegen.stamp
XCODEGEN_INPUTS := .xcodegen.inputs
XCODEPROJ := NuxieSDK.xcodeproj
SCHEME_UNIT := NuxieSDKUnitTests
SCHEME_MACOS_UNIT := NuxieSDKMacUnitTests
SCHEME_INTEGRATION := NuxieSDKIntegrationTests
SCHEME_E2E := NuxieSDKE2ETests
SCHEME_FLOW_RUNTIME_UI := NuxieFlowRuntimeUITests
SCHEME_MACOS := NuxieSDKMac
SCHEME_REFERENCE_APP := NuxieFlowRuntimeReferenceApp
SCHEME ?= $(SCHEME_UNIT)
DERIVED_DATA := DerivedData
DEFAULT_SIMULATOR_OS := $(shell xcrun simctl list devices available 2>/dev/null | sed -n 's/^-- iOS \(.*\) --/\1/p' | sort -V | tail -1)
DEFAULT_SIMULATOR_NAME := $(shell \
	if [ -n "$(DEFAULT_SIMULATOR_OS)" ]; then \
		xcrun simctl list devices available 2>/dev/null | awk -v ver="$(DEFAULT_SIMULATOR_OS)" '\
			$$0 == "-- iOS " ver " --" { in_ver = 1; next } \
			in_ver && /^-- / { exit } \
			in_ver && /^[[:space:]]+iPhone 17 Pro \(/ { print "iPhone 17 Pro"; exit } \
			in_ver && /^[[:space:]]+iPhone / { \
				name = $$0; \
				sub(/^[[:space:]]+/, "", name); \
				sub(/ \([^)]+\) \((Shutdown|Booted)\)$$/, "", name); \
				print name; \
				exit \
			}'; \
	fi)
TEST_SIMULATOR_OS ?= $(if $(DEFAULT_SIMULATOR_OS),$(DEFAULT_SIMULATOR_OS),26.3)
TEST_SIMULATOR_NAME ?= $(if $(DEFAULT_SIMULATOR_NAME),$(DEFAULT_SIMULATOR_NAME),iPhone 17 Pro)
TEST_DESTINATION ?= platform=iOS Simulator,name=$(TEST_SIMULATOR_NAME),OS=$(TEST_SIMULATOR_OS)
XCODEBUILD_TEST_FLAGS ?=

# Default target
help:
	@echo "Available targets:"
	@echo "  generate         - Generate Xcode project using XcodeGen"
	@echo "  test             - Run unit tests (default)"
	@echo "  test-ios         - Run tests on iOS simulator (alias)"
	@echo "  test-unit        - Run unit tests"
	@echo "  test-macos-unit  - Run unit tests on macOS"
	@echo "  test-integration - Run integration tests"
	@echo "  test-e2e         - Run the example app end-to-end tests"
	@echo "  test-flow-runtime-ui - Run native flow runtime UI screenshot tests"
	@echo "  test-all         - Run unit + integration tests"
	@echo "  build-macos      - Build macOS framework target"
	@echo "  build-reference-app - Build the native flow runtime reference app"
	@echo "  install-reference-app - Install the reference app on the selected simulator"
	@echo "  coverage         - Run tests with code coverage (Swift Package Manager)"
	@echo "  coverage-html    - Generate HTML coverage report"
	@echo "  coverage-json    - Export coverage as JSON (Xcode)"
	@echo "  coverage-summary - Show coverage summary"
	@echo "  clean            - Remove generated Xcode project files and coverage data"
	@echo "  install-deps     - Install required dependencies (XcodeGen)"

# Check if XcodeGen is installed
check-xcodegen:
	@which xcodegen > /dev/null || (echo "XcodeGen not found. Run 'make install-deps' to install." && exit 1)

# Install dependencies
install-deps:
	@echo "Installing XcodeGen..."
	@brew install xcodegen || echo "Homebrew not found. Please install XcodeGen manually: https://github.com/yonaskolb/XcodeGen"

# Generate Xcode project
generate: check-xcodegen
	@CURRENT_HASH=$$( (cat project.yml; find Sources Tests Examples -type f -print | sort) | shasum -a 256 | awk '{print $$1}' ); \
	STORED_HASH=$$(cat "$(XCODEGEN_INPUTS)" 2>/dev/null || true); \
	if [ -d "$(XCODEPROJ)" ] && [ "$$CURRENT_HASH" = "$$STORED_HASH" ]; then \
		echo "Xcode project is up to date."; \
	else \
		echo "Generating Xcode project..."; \
		xcodegen generate; \
		echo "$$CURRENT_HASH" > "$(XCODEGEN_INPUTS)"; \
		touch "$(XCODEGEN_STAMP)"; \
	fi
	@scripts/sync-package-pins.sh seed

# Run tests on iOS simulator
test-xcode: generate
	@echo "Running tests on iOS Simulator..."
	@xcodebuild test \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination '$(TEST_DESTINATION)' \
		$(XCODEBUILD_TEST_FLAGS)

test-unit: SCHEME = $(SCHEME_UNIT)
test-unit: test-xcode

test-macos-unit: generate
	@echo "Running unit tests on macOS..."
	@xcodebuild test \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_MACOS_UNIT)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination 'platform=macOS' \
		$(XCODEBUILD_TEST_FLAGS)

test-integration: SCHEME = $(SCHEME_INTEGRATION)
test-integration: test-xcode

test-e2e: SCHEME = $(SCHEME_E2E)
test-e2e: test-xcode

test-flow-runtime-ui: generate
	@echo "Running native flow runtime UI tests on iOS Simulator..."
	@TEST_DESTINATION='$(TEST_DESTINATION)' \
		TEST_SIMULATOR_NAME='$(TEST_SIMULATOR_NAME)' \
		TEST_SIMULATOR_OS='$(TEST_SIMULATOR_OS)' \
		scripts/run-flow-runtime-ui-tests.sh

test-all: test-unit test-integration

# Alias for test-ios
test: test-unit
test-ios: test

build-macos: generate
	@echo "Building macOS framework..."
	@xcodebuild build \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_MACOS)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination 'generic/platform=macOS'

build-reference-app: generate
	@echo "Building flow runtime reference app..."
	@xcodebuild build \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_REFERENCE_APP)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination '$(TEST_DESTINATION)'

install-reference-app: build-reference-app
	@APP_PATH="$$(find "$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name 'NuxieFlowRuntimeReference.app' -print -quit)"; \
	if [ -z "$$APP_PATH" ]; then \
		echo "Reference app bundle was not found."; \
		exit 1; \
	fi; \
	UDID="$$(xcrun simctl list devices available 2>/dev/null | awk -v name="$(TEST_SIMULATOR_NAME)" -v os="$(TEST_SIMULATOR_OS)" '\
		$$0 == "-- iOS " os " --" { in_os = 1; next } \
		in_os && /^-- / { exit } \
		in_os && index($$0, name " (") > 0 { print $$0; exit }' | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')"; \
	if [ -z "$$UDID" ]; then \
		echo "Could not resolve simulator for $(TEST_SIMULATOR_NAME) $(TEST_SIMULATOR_OS)."; \
		exit 1; \
	fi; \
	xcrun simctl boot "$$UDID" >/dev/null 2>&1 || true; \
	xcrun simctl install "$$UDID" "$$APP_PATH"; \
	xcrun simctl launch "$$UDID" com.nuxie.sdk.flow-runtime-reference

# Run tests with code coverage (Swift Package Manager)
coverage:
	@./scripts/coverage.sh swift

# Generate HTML coverage report
coverage-html:
	@./scripts/coverage.sh html --open

# Export coverage as JSON (using Xcode)
coverage-json:
	@./scripts/coverage.sh json

# Show coverage summary
coverage-summary:
	@./scripts/coverage.sh summary

# Clean generated files
clean:
	@echo "Cleaning generated files..."
	@rm -rf *.xcodeproj
	@rm -rf *.xcworkspace
	@rm -f "$(XCODEGEN_STAMP)"
	@rm -f "$(XCODEGEN_INPUTS)"
	@rm -rf DerivedData
	@rm -rf .build
	@rm -rf coverage
	@./scripts/coverage.sh clean 2>/dev/null || true
	@echo "Clean complete."
