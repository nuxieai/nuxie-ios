.PHONY: generate test test-ios test-xcode test-unit test-native-runtime test-runtime-reference-ui test-macos-unit test-integration test-e2e test-experience-runtime-ui test-flow-runtime-ui test-all build-ios-device build-macos build-reference-app verify-customer-framework verify-runtime-reference-app verify-runtime-native-archive verify-runtime-artifact install-reference-app clean help coverage coverage-html coverage-json coverage-summary install-deps check-xcodegen check-privacy-manifest check-public-api check-product-neutrality test-product-neutrality check-runtime-module-boundary test-runtime-module-boundary test-runtime-consumer-boundary check-runtime-package-pin check-sdk-guidance check-provider-adapters stage-runtime-xcframework fetch-runtime-xcframework fetch-runtime-xcframework-clean check-staged-runtime-xcframework check-local-runtime-xcframework check-concurrency-warnings

XCODEGEN_STAMP := .xcodegen.stamp
XCODEGEN_INPUTS := .xcodegen.inputs
XCODEPROJ := NuxieSDK.xcodeproj
SCHEME_UNIT := NuxieSDKUnitTests
SCHEME_MACOS_UNIT := NuxieSDKMacUnitTests
SCHEME_INTEGRATION := NuxieSDKIntegrationTests
SCHEME_E2E := NuxieSDKE2ETests
SCHEME_EXPERIENCE_RUNTIME_UI := NuxieExperienceRuntimeUITests
SCHEME_RUNTIME_REFERENCE_UI := NuxieExperienceRuntimeReferenceUITests
SCHEME_IOS := NuxieSDK
SCHEME_MACOS := NuxieSDKMac
SCHEME_REFERENCE_APP := NuxieExperienceRuntimeReferenceApp
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
RUNTIME_ARTIFACTS_DIR := .artifacts
STAGED_RUNTIME_XCFRAMEWORK := $(RUNTIME_ARTIFACTS_DIR)/NuxieRuntime.xcframework
RUNTIME_ARTIFACT_METADATA := Runtime/artifact.json
DOWNLOADED_RUNTIME_ARCHIVE := $(RUNTIME_ARTIFACTS_DIR)/NuxieRuntime.xcframework.zip
NUXIE_RUNTIME_REFERENCE_APP := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/NuxieExperienceRuntimeReference.app
NUXIE_FRAMEWORK ?= $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/Nuxie.framework

# Default target
help:
	@echo "Available targets:"
	@echo "  generate         - Generate Xcode project using XcodeGen"
	@echo "  test             - Run the full unit + native-runtime + integration + macOS gate"
	@echo "  test-ios         - Alias for the full test gate"
	@echo "  test-unit        - Run unit tests"
	@echo "  test-native-runtime - Test the Swift-owned runtime and product harness"
	@echo "  test-runtime-reference-ui - Prove first-frame presentation in the standalone app"
	@echo "  test-macos-unit  - Run unit tests on macOS"
	@echo "  test-integration - Run integration tests"
	@echo "  test-e2e         - Run the example app end-to-end tests"
	@echo "  test-experience-runtime-ui - Run signed release runtime UI tests"
	@echo "  test-all         - Run unit + native-runtime + integration + macOS tests"
	@echo "  build-ios-device - Link and audit the Release framework for a generic iOS device"
	@echo "  build-macos      - Build macOS framework target"
	@echo "  build-reference-app - Build the signed release runtime reference app"
	@echo "  verify-customer-framework - Audit the assembled Nuxie.framework"
	@echo "  verify-runtime-native-archive - Audit the framework and runtime archives for Rust-only linkage"
	@echo "  verify-runtime-artifact - Verify the released archive checksum, slices, headers, and ABI"
	@echo "  verify-runtime-reference-app - Audit the app's runtime symbols and dependencies"
	@echo "  install-reference-app - Install the reference app on the selected simulator"
	@echo "  fetch-runtime-xcframework - Download, checksum, verify, and stage the released runtime"
	@echo "  fetch-runtime-xcframework-clean - Re-download and qualify without reusing a cached archive"
	@echo "  stage-runtime-xcframework - Verify and stage NUXIE_RUNTIME_XCFRAMEWORK for local development"
	@echo "  check-staged-runtime-xcframework - Bind the staged runtime to the release pin (or explicit local opt-in)"
	@echo "  check-local-runtime-xcframework - Structurally validate an explicitly selected local runtime"
	@echo "  check-privacy-manifest - Validate the SDK-wide privacy inventory"
	@echo "  check-public-api    - Reject accidental changes to the supported SDK facade"
	@echo "  check-product-neutrality - Reject Editor-product-specific SDK support"
	@echo "  test-product-neutrality - Prove the product-neutrality guard fails closed"
	@echo "  check-runtime-module-boundary - Enforce SDK -> Swift runtime -> FFI layering"
	@echo "  check-runtime-consumer-boundary - Reject Rust build and runtime source ownership"
	@echo "  check-runtime-package-pin - Match SwiftPM binary target to release metadata"
	@echo "  check-concurrency-warnings - Fail if strict-concurrency warnings exceed the baseline (0)"
	@echo "  check-sdk-guidance - Verify top-level SDK examples match the public surface"
	@echo "  check-provider-adapters - Compile maintained provider sources and prove SPI stays hidden"
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

check-public-api:
	@scripts/check-public-api.sh

check-product-neutrality:
	@scripts/check-product-neutrality.sh

test-product-neutrality:
	@scripts/test-check-product-neutrality.sh

check-runtime-module-boundary: test-runtime-module-boundary
	@bash scripts/check-runtime-module-boundary.sh

test-runtime-module-boundary:
	@bash scripts/test-check-runtime-module-boundary.sh

check-runtime-consumer-boundary:
	@bash scripts/check-runtime-consumer-boundary.sh

check-runtime-package-pin:
	@python3 scripts/check-runtime-package-pin.py Runtime/artifact.json

# The currently protected reusable-workflow pin predates the macOS target's
# binary dependency and does not stage it in that one job. Its `make generate`
# command executes this candidate-controlled target, so bridge the pin safely
# until the next reviewed workflow-pin advance. Other jobs already stage the
# artifact explicitly, and local project generation remains network-free.
generate: check-xcodegen check-privacy-manifest
	@if [ "$${GITHUB_JOB:-}" = "macos-build" ]; then \
		$(MAKE) fetch-runtime-xcframework; \
	fi
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

# XcodeGen consumes the staged path directly. Runtime contributors can point
# this target at a local runtime build; NUXIE_RUNTIME_USE_LOCAL=1 then opts
# SwiftPM and staged-runtime checks into that unpublished artifact.
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
	scripts/verify-runtime-artifact.sh --xcframework "$$candidate"; \
	rm -rf "$(STAGED_RUNTIME_XCFRAMEWORK)"; \
	mv "$$candidate" "$(STAGED_RUNTIME_XCFRAMEWORK)"; \
	echo "Staged $(STAGED_RUNTIME_XCFRAMEWORK)"

# Download and stage the immutable release declared in Runtime/artifact.json.
# The fetcher checks the archive before extraction and the verifier checks the
# public Apple contract without compiling or inspecting Rust source.
fetch-runtime-xcframework:
	@scripts/fetch-runtime-xcframework.sh \
		"$(RUNTIME_ARTIFACT_METADATA)" \
		"$(DOWNLOADED_RUNTIME_ARCHIVE)" \
		"$(STAGED_RUNTIME_XCFRAMEWORK)"

# Final release qualification must prove that a cached migration archive cannot
# influence selection. The fetch remains atomic: the existing stage is replaced
# only after the newly downloaded archive passes the slim-runtime contract.
fetch-runtime-xcframework-clean:
	@scripts/fetch-runtime-xcframework.sh \
		"$(RUNTIME_ARTIFACT_METADATA)" \
		"$(DOWNLOADED_RUNTIME_ARCHIVE)" \
		"$(STAGED_RUNTIME_XCFRAMEWORK)" \
		--fresh

verify-runtime-artifact:
	@scripts/verify-runtime-artifact.sh \
		--metadata "$(RUNTIME_ARTIFACT_METADATA)" \
		--archive "$(DOWNLOADED_RUNTIME_ARCHIVE)" \
		--xcframework "$(STAGED_RUNTIME_XCFRAMEWORK)"

check-staged-runtime-xcframework:
	@set -eu; \
	case "$${NUXIE_RUNTIME_USE_LOCAL:-}" in \
		"") \
			scripts/verify-runtime-artifact.sh \
				--metadata "$(RUNTIME_ARTIFACT_METADATA)" \
				--archive "$(DOWNLOADED_RUNTIME_ARCHIVE)" \
				--xcframework "$(STAGED_RUNTIME_XCFRAMEWORK)" \
			;; \
		1) $(MAKE) --no-print-directory check-local-runtime-xcframework ;; \
		*) echo "NUXIE_RUNTIME_USE_LOCAL must be unset or 1" >&2; exit 64 ;; \
	esac

check-local-runtime-xcframework:
	@if [ ! -d "$(STAGED_RUNTIME_XCFRAMEWORK)" ]; then \
		echo "Local NuxieRuntime is not staged. Run 'make stage-runtime-xcframework NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework'." >&2; \
		exit 1; \
	fi
	@scripts/verify-runtime-artifact.sh --xcframework "$(STAGED_RUNTIME_XCFRAMEWORK)"

# Strict-concurrency warning ratchet (Swift 6 compatibility): clean-builds the
# iOS framework (SWIFT_STRICT_CONCURRENCY=complete) into a scratch DerivedData
# and fails if unique strict-concurrency warnings exceed the baseline.
# Ratchet down, never up.
CONCURRENCY_DERIVED_DATA := DerivedData-concurrency
CONCURRENCY_WARNING_BASELINE := 0

check-concurrency-warnings: check-staged-runtime-xcframework generate
	@scripts/check-concurrency-warnings.sh "$(XCODEPROJ)" "$(SCHEME_IOS)" "$(CONCURRENCY_DERIVED_DATA)" "$(CONCURRENCY_WARNING_BASELINE)"

check-sdk-guidance:
	@bash scripts/check-sdk-guidance.sh

check-provider-adapters:
	@bash scripts/check-provider-adapter-boundary.sh

# Run tests on iOS simulator
test-xcode: test-product-neutrality check-staged-runtime-xcframework generate
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

test-native-runtime: check-staged-runtime-xcframework
	@$(MAKE) test-xcode SCHEME=NuxieSDKUnitTests XCODEBUILD_TEST_FLAGS='-quiet -only-testing:NuxieSDKUnitTests/NuxieNativeRuntimeTests -only-testing:NuxieSDKUnitTests/ExperienceInteractiveScreenTests -only-testing:NuxieSDKUnitTests/ExperienceRuntimePresentationLoopTests'

test-runtime-reference-ui: check-staged-runtime-xcframework generate
	@echo "Testing first-frame presentation through the standalone runtime app..."
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

test-experience-runtime-ui: check-staged-runtime-xcframework generate
	@echo "Running signed release runtime UI tests on iOS Simulator..."
	@TEST_DESTINATION='$(TEST_DESTINATION)' \
		TEST_SIMULATOR_NAME='$(TEST_SIMULATOR_NAME)' \
		TEST_SIMULATOR_OS='$(TEST_SIMULATOR_OS)' \
		SCHEME_EXPERIENCE_RUNTIME_UI='$(SCHEME_EXPERIENCE_RUNTIME_UI)' \
		scripts/run-experience-runtime-ui-tests.sh

# Compatibility for the SHA-pinned trusted workflow. Remove after test.yml is
# repinned to a revision that calls test-experience-runtime-ui.
test-flow-runtime-ui: test-experience-runtime-ui

# The holistic gate: iOS unit + focused native-runtime + integration
# (orchestration + conformance-fixture runners live in these schemes) + macOS unit.
test-all: check-sdk-guidance check-provider-adapters
	@$(MAKE) test-unit
	@$(MAKE) test-native-runtime
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
	@echo "Building signed release runtime reference app..."
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

verify-runtime-native-archive:
	@test -n "$(NUXIE_RUNTIME_XCFRAMEWORK)" || { echo "Set NUXIE_RUNTIME_XCFRAMEWORK." >&2; exit 1; }
	@scripts/verify-runtime-native-archive.sh \
		"$(NUXIE_FRAMEWORK)" \
		"$(NUXIE_RUNTIME_XCFRAMEWORK)"

install-reference-app: build-reference-app
	@APP_PATH="$$(find "$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name 'NuxieExperienceRuntimeReference.app' -print -quit)"; \
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
	xcrun simctl launch "$$UDID" com.nuxie.sdk.experience-runtime-reference

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
