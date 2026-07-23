.PHONY: generate test test-ios test-xcode test-unit test-runtime-adapter test-editor-next-production-artifact stage-editor-next-native-ui-fixtures test-editor-next-native-pixels test-editor-next-native-archive test-runtime-reference-ui test-macos-unit test-integration test-e2e test-flow-runtime-ui test-all build-ios-device build-macos build-reference-app verify-customer-framework verify-runtime-reference-app install-reference-app clean help coverage coverage-html coverage-json coverage-summary install-deps check-xcodegen check-privacy-manifest stage-runtime-xcframework fetch-runtime-xcframework check-staged-runtime-xcframework check-concurrency-warnings

XCODEGEN_STAMP := .xcodegen.stamp
XCODEGEN_INPUTS := .xcodegen.inputs
XCODEPROJ := NuxieSDK.xcodeproj
SCHEME_UNIT := NuxieSDKUnitTests
SCHEME_MACOS_UNIT := NuxieSDKMacUnitTests
SCHEME_INTEGRATION := NuxieSDKIntegrationTests
SCHEME_E2E := NuxieSDKE2ETests
SCHEME_FLOW_RUNTIME_UI := NuxieFlowRuntimeUITests
SCHEME_RUNTIME_REFERENCE_UI := NuxieFlowRuntimeReferenceUITests
SCHEME_IOS := NuxieSDK
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
NUXIE_RUNTIME_XCFRAMEWORK ?=
NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR ?=
RUNTIME_ARTIFACTS_DIR := .artifacts
STAGED_RUNTIME_XCFRAMEWORK := $(RUNTIME_ARTIFACTS_DIR)/NuxieRuntime.xcframework
RUNTIME_RELEASE_URL := https://github.com/nuxieai/nuxie-runtime/releases/download/apple-runtime-v0.1.0/NuxieRuntime.xcframework.zip
RUNTIME_RELEASE_CHECKSUM := 5ada29f067a278c80b199cf6b95587103a6e12d62a2fb002283fd107d784c0d8
NUXIE_RUNTIME_REFERENCE_APP := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/NuxieFlowRuntimeReference.app
NUXIE_FRAMEWORK ?= $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/Nuxie.framework

# Default target
help:
	@echo "Available targets:"
	@echo "  generate         - Generate Xcode project using XcodeGen"
	@echo "  test             - Run unit tests (default)"
	@echo "  test-ios         - Run tests on iOS simulator (alias)"
	@echo "  test-unit        - Run unit tests"
	@echo "  test-runtime-adapter - Test the concrete adapter against a local XCFramework"
	@echo "  test-editor-next-production-artifact - Test the exact P17 corpus against the shipped XCFramework"
	@echo "  test-editor-next-native-pixels - Test all exact P17 and signed GPU pixels in the production host"
	@echo "  test-editor-next-native-archive - Audit the production archive for Rust-only linkage"
	@echo "  test-runtime-reference-ui - Prove first-frame presentation in the standalone app"
	@echo "  test-macos-unit  - Run unit tests on macOS"
	@echo "  test-integration - Run integration tests"
	@echo "  test-e2e         - Run the example app end-to-end tests"
	@echo "  test-flow-runtime-ui - Run native flow runtime UI screenshot tests"
	@echo "  test-all         - Run unit + integration tests"
	@echo "  build-ios-device - Link and audit the Release framework for a generic iOS device"
	@echo "  build-macos      - Build macOS framework target"
	@echo "  build-reference-app - Build the native flow runtime reference app"
	@echo "  verify-customer-framework - Audit the assembled Nuxie.framework"
	@echo "  verify-runtime-reference-app - Audit the app's runtime symbols and dependencies"
	@echo "  install-reference-app - Install the reference app on the selected simulator"
	@echo "  stage-runtime-xcframework - Validate and stage NUXIE_RUNTIME_XCFRAMEWORK"
	@echo "  fetch-runtime-xcframework - Download, checksum, and stage the pinned runtime release"
	@echo "  check-staged-runtime-xcframework - Validate the staged runtime used by iOS builds"
	@echo "  check-privacy-manifest - Validate the SDK-wide privacy inventory"
	@echo "  check-concurrency-warnings - Fail if strict-concurrency warnings exceed the baseline (0)"
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

check-privacy-manifest:
	@scripts/validate-privacy-manifest.py Sources/Nuxie/PrivacyInfo.xcprivacy

# Generate Xcode project
generate: check-xcodegen check-privacy-manifest
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

# Stage the exact runtime archive consumed by XcodeGen builds. The copy is
# assembled and validated in a sibling temporary directory before replacing
# the currently staged artifact, so a bad input cannot leave a partial bundle.
stage-runtime-xcframework:
	@set -eu; \
	source="$(NUXIE_RUNTIME_XCFRAMEWORK)"; \
	if [ -z "$$source" ]; then \
		echo "Set NUXIE_RUNTIME_XCFRAMEWORK to a built NuxieRuntime.xcframework" >&2; \
		exit 1; \
	fi; \
	if [ ! -d "$$source" ]; then \
		echo "Runtime XCFramework not found: $$source" >&2; \
		exit 1; \
	fi; \
	mkdir -p "$(RUNTIME_ARTIFACTS_DIR)"; \
	temporary=$$(mktemp -d "$(RUNTIME_ARTIFACTS_DIR)/.runtime-stage.XXXXXX"); \
	trap 'rm -rf "$$temporary"' EXIT; \
	candidate="$$temporary/NuxieRuntime.xcframework"; \
	ditto "$$source" "$$candidate"; \
	scripts/validate-runtime-xcframework.sh "$$candidate"; \
	rm -rf "$(STAGED_RUNTIME_XCFRAMEWORK)"; \
	mv "$$candidate" "$(STAGED_RUNTIME_XCFRAMEWORK)"; \
	echo "Staged $(STAGED_RUNTIME_XCFRAMEWORK)"

# CI and clean-room qualification use the same immutable archive declared by
# Package.swift. A checksum mismatch fails before any artifact is staged.
fetch-runtime-xcframework:
	@set -eu; \
	temporary=$$(mktemp -d); \
	trap 'rm -rf "$$temporary"' EXIT; \
	archive="$$temporary/NuxieRuntime.xcframework.zip"; \
	unpacked="$$temporary/unpacked"; \
	curl --fail --location --retry 3 --output "$$archive" "$(RUNTIME_RELEASE_URL)"; \
	actual=$$(shasum -a 256 "$$archive" | awk '{print $$1}'); \
	if [ "$$actual" != "$(RUNTIME_RELEASE_CHECKSUM)" ]; then \
		echo "Runtime checksum mismatch: expected $(RUNTIME_RELEASE_CHECKSUM), got $$actual" >&2; \
		exit 1; \
	fi; \
	mkdir -p "$$unpacked"; \
	ditto -x -k "$$archive" "$$unpacked"; \
	runtime=$$(find "$$unpacked" -type d -name NuxieRuntime.xcframework -print -quit); \
	if [ -z "$$runtime" ]; then \
		echo "Pinned runtime archive does not contain NuxieRuntime.xcframework" >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory stage-runtime-xcframework NUXIE_RUNTIME_XCFRAMEWORK="$$runtime"

check-staged-runtime-xcframework:
	@if [ ! -d "$(STAGED_RUNTIME_XCFRAMEWORK)" ]; then \
		echo "NuxieRuntime is not staged. Run 'make stage-runtime-xcframework NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework'." >&2; \
		exit 1; \
	fi
	@scripts/validate-runtime-xcframework.sh "$(STAGED_RUNTIME_XCFRAMEWORK)"

# Strict-concurrency warning ratchet (Swift 6 compatibility): clean-builds the
# iOS framework (SWIFT_STRICT_CONCURRENCY=complete) into a scratch DerivedData
# and fails if unique strict-concurrency warnings exceed the baseline.
# Ratchet down, never up.
CONCURRENCY_DERIVED_DATA := DerivedData-concurrency
CONCURRENCY_WARNING_BASELINE := 0

check-concurrency-warnings: check-staged-runtime-xcframework generate
	@scripts/check-concurrency-warnings.sh "$(XCODEPROJ)" "$(SCHEME_IOS)" "$(CONCURRENCY_DERIVED_DATA)" "$(CONCURRENCY_WARNING_BASELINE)"

# Run tests on iOS simulator
test-xcode: check-staged-runtime-xcframework generate
	@echo "Running tests on iOS Simulator..."
	@xcodebuild test \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination '$(TEST_DESTINATION)' \
		$(XCODEBUILD_TEST_FLAGS)
	@$(MAKE) verify-customer-framework

test-unit: SCHEME = $(SCHEME_UNIT)
test-unit: test-xcode

test-runtime-adapter: check-staged-runtime-xcframework
	@$(MAKE) test-unit XCODEBUILD_TEST_FLAGS='-quiet -only-testing:NuxieSDKUnitTests/NuxieRuntimeAdapterTests -only-testing:NuxieSDKUnitTests/NuxieRuntimeFixtureTraceTests -only-testing:NuxieSDKUnitTests/NuxieRuntimeNativeResultSeamTests -only-testing:NuxieSDKUnitTests/FlowRuntimeStateBridgeTests'

test-editor-next-production-artifact:
	@set -eu; \
	artifact_root="$(NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR)"; \
	if [ -z "$$artifact_root" ]; then \
		echo "Set NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR to the exact P17 corpus directory." >&2; \
		exit 1; \
	fi; \
	artifact_pointer="$(RUNTIME_ARTIFACTS_DIR)/editor-next-production-artifact-root"; \
	native_sentinel="$$artifact_root/ios-native-consumed.ok"; \
	pipeline_sentinel="$$artifact_root/ios-sdk-pipeline-consumed.ok"; \
	test_succeeded=0; \
	trap 'rm -f "$$artifact_pointer"; if [ "$$test_succeeded" -ne 1 ]; then rm -f "$$native_sentinel" "$$pipeline_sentinel"; fi' EXIT; \
	rm -f "$$artifact_pointer" "$$native_sentinel" "$$pipeline_sentinel"; \
	if [ ! -d "$$artifact_root" ]; then \
		echo "Exact P17 corpus directory not found: $$artifact_root" >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory fetch-runtime-xcframework; \
	$(MAKE) --no-print-directory generate; \
	printf '%s\n' "$$artifact_root" > "$$artifact_pointer"; \
	echo "Testing the exact P17 corpus through the shipped NuxieRuntime.xcframework..."; \
	NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR="$$artifact_root" \
	xcodebuild test \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_UNIT)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination '$(TEST_DESTINATION)' \
		-quiet \
		-only-testing:NuxieSDKUnitTests/EditorNextNativeArtifactTests; \
	node scripts/write-editor-next-artifact-sentinel.mjs \
		"$$artifact_root" "ios-native-consumed.ok" "ios-native-runtime"; \
	node scripts/write-editor-next-artifact-sentinel.mjs \
		"$$artifact_root" "ios-sdk-pipeline-consumed.ok" "ios-sdk-pipeline"; \
	test_succeeded=1

stage-editor-next-native-ui-fixtures:
	@artifact_root="$(NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR)"; \
	if [ -z "$$artifact_root" ]; then \
		echo "Set NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR to the exact P17 corpus directory." >&2; \
		exit 1; \
	fi; \
	node scripts/stage-editor-next-native-ui-fixtures.mjs "$$artifact_root"

test-editor-next-native-pixels:
	@set -eu; \
	artifact_root="$(NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR)"; \
	if [ -z "$$artifact_root" ]; then \
		echo "Set NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR to the exact P17 corpus directory." >&2; \
		exit 1; \
	fi; \
	gpu_sentinel="$$artifact_root/ios-gpu-canvas-pixels.ok"; \
	corpus_sentinel="$$artifact_root/ios-native-corpus-pixels.ok"; \
	test_succeeded=0; \
	trap 'if [ "$$test_succeeded" -ne 1 ]; then rm -f "$$gpu_sentinel" "$$corpus_sentinel"; fi' EXIT; \
	rm -f "$$gpu_sentinel" "$$corpus_sentinel"; \
	if [ ! -d "$$artifact_root" ]; then \
		echo "Exact P17 corpus directory not found: $$artifact_root" >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory fetch-runtime-xcframework; \
	$(MAKE) --no-print-directory stage-editor-next-native-ui-fixtures \
		NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR="$$artifact_root"; \
	$(MAKE) --no-print-directory generate; \
	xcodebuild test \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_FLOW_RUNTIME_UI)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination '$(TEST_DESTINATION)' \
		-quiet \
		-only-testing:NuxieFlowRuntimeUITests/EditorNextNativeArtifactPixelTests; \
	node scripts/write-editor-next-artifact-sentinel.mjs \
		"$$artifact_root" "ios-gpu-canvas-pixels.ok" "ios-gpu-canvas-pixels"; \
	node scripts/write-editor-next-artifact-sentinel.mjs \
		"$$artifact_root" "ios-native-corpus-pixels.ok" "ios-native-corpus-pixels"; \
	test_succeeded=1

test-editor-next-native-archive:
	@set -eu; \
	artifact_root="$(NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR)"; \
	if [ -z "$$artifact_root" ]; then \
		echo "Set NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR to the exact P17 corpus directory." >&2; \
		exit 1; \
	fi; \
	sentinel="$$artifact_root/ios-native-runtime-archive.ok"; \
	test_succeeded=0; \
	trap 'if [ "$$test_succeeded" -ne 1 ]; then rm -f "$$sentinel"; fi' EXIT; \
	rm -f "$$sentinel"; \
	if [ ! -d "$$artifact_root" ]; then \
		echo "Exact P17 corpus directory not found: $$artifact_root" >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory fetch-runtime-xcframework; \
	$(MAKE) --no-print-directory generate; \
	$(MAKE) --no-print-directory build-ios-device; \
	scripts/verify-editor-next-native-archive.sh \
		"$(DERIVED_DATA)/Build/Products/Release-iphoneos/Nuxie.framework" \
		"$(STAGED_RUNTIME_XCFRAMEWORK)"; \
	node scripts/write-editor-next-artifact-sentinel.mjs \
		"$$artifact_root" "ios-native-runtime-archive.ok" "ios-native-runtime-archive"; \
	test_succeeded=1

test-runtime-reference-ui: check-staged-runtime-xcframework generate
	@echo "Testing first-frame presentation through the standalone Rust runtime app..."
	@xcodebuild test \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_RUNTIME_REFERENCE_UI)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination '$(TEST_DESTINATION)'
	@$(MAKE) verify-runtime-reference-app

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

test-flow-runtime-ui: check-staged-runtime-xcframework generate
	@echo "Running native flow runtime UI tests on iOS Simulator..."
	@TEST_DESTINATION='$(TEST_DESTINATION)' \
		TEST_SIMULATOR_NAME='$(TEST_SIMULATOR_NAME)' \
		TEST_SIMULATOR_OS='$(TEST_SIMULATOR_OS)' \
		scripts/run-flow-runtime-ui-tests.sh

# The holistic gate (cleanup P10): unit + integration (orchestration +
# conformance-fixture runners live in these schemes) + macOS unit.
test-all:
	@$(MAKE) test-unit
	@$(MAKE) test-integration
	@$(MAKE) test-macos-unit

# `make test` IS the holistic gate — running less locally is opt-in
# (test-unit / test-integration / test-macos-unit directly).
test: test-all
test-ios: test

build-ios-device: check-staged-runtime-xcframework generate
	@echo "Building Release framework for a generic iOS device..."
	@xcodebuild build \
		-quiet \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_IOS)" \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination 'generic/platform=iOS' \
		$(if $(CLONED_SOURCE_PACKAGES_DIR_PATH),-clonedSourcePackagesDirPath "$(CLONED_SOURCE_PACKAGES_DIR_PATH)") \
		CODE_SIGNING_ALLOWED=NO
	@$(MAKE) verify-customer-framework \
		NUXIE_FRAMEWORK="$(DERIVED_DATA)/Build/Products/Release-iphoneos/Nuxie.framework"

build-macos: generate
	@echo "Building macOS framework..."
	@xcodebuild build \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_MACOS)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination 'generic/platform=macOS'

build-reference-app: check-staged-runtime-xcframework generate
	@echo "Building flow runtime reference app..."
	@xcodebuild build \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME_REFERENCE_APP)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination '$(TEST_DESTINATION)'
	@$(MAKE) verify-runtime-reference-app

verify-runtime-reference-app:
	@scripts/verify-runtime-reference-app.sh "$(NUXIE_RUNTIME_REFERENCE_APP)"

verify-customer-framework:
	@scripts/verify-customer-framework.sh "$(NUXIE_FRAMEWORK)"

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
	@rm -rf DerivedData-concurrency
	@rm -rf .build
	@rm -rf coverage
	@./scripts/coverage.sh clean 2>/dev/null || true
	@echo "Clean complete."
