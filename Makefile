.PHONY: generate test test-ios test-xcode test-unit test-runtime-adapter test-runtime-reference-ui test-macos-unit test-integration test-e2e test-experience-runtime-ui test-all build-ios-device build-macos build-reference-app verify-customer-framework verify-runtime-reference-app verify-runtime-native-archive install-reference-app clean help coverage coverage-html coverage-json coverage-summary install-deps check-xcodegen check-privacy-manifest check-product-neutrality test-product-neutrality build-runtime-xcframework stage-runtime-xcframework unpack-runtime-xcframework package-runtime-xcframework write-runtime-provenance check-runtime-provenance check-staged-runtime-xcframework check-concurrency-warnings

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
COMMITTED_RUNTIME_ARCHIVE := Runtime/NuxieRuntime.xcframework.zip
RUNTIME_PROVENANCE := Runtime/provenance.json
NUXIE_RUNTIME_REFERENCE_APP := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/NuxieExperienceRuntimeReference.app
NUXIE_FRAMEWORK ?= $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/Nuxie.framework

# Default target
help:
	@echo "Available targets:"
	@echo "  generate         - Generate Xcode project using XcodeGen"
	@echo "  test             - Run unit tests (default)"
	@echo "  test-ios         - Run tests on iOS simulator (alias)"
	@echo "  test-unit        - Run unit tests"
	@echo "  test-runtime-adapter - Test the concrete adapter against a local XCFramework"
	@echo "  test-runtime-reference-ui - Prove first-frame presentation in the standalone app"
	@echo "  test-macos-unit  - Run unit tests on macOS"
	@echo "  test-integration - Run integration tests"
	@echo "  test-e2e         - Run the example app end-to-end tests"
	@echo "  test-experience-runtime-ui - Run signed package runtime UI tests"
	@echo "  test-all         - Run unit + integration tests"
	@echo "  build-ios-device - Link and audit the Release framework for a generic iOS device"
	@echo "  build-macos      - Build macOS framework target"
	@echo "  build-reference-app - Build the signed package runtime reference app"
	@echo "  verify-customer-framework - Audit the assembled Nuxie.framework"
	@echo "  verify-runtime-native-archive - Audit the framework and runtime archives for Rust-only linkage"
	@echo "  verify-runtime-reference-app - Audit the app's runtime symbols and dependencies"
	@echo "  install-reference-app - Install the reference app on the selected simulator"
	@echo "  build-runtime-xcframework - Build and stage the SDK-owned Rust runtime"
	@echo "  stage-runtime-xcframework - Validate and stage NUXIE_RUNTIME_XCFRAMEWORK"
	@echo "  unpack-runtime-xcframework - Unpack, validate, and stage the committed runtime"
	@echo "  package-runtime-xcframework - Refresh the committed runtime and provenance"
	@echo "  write-runtime-provenance - Record the current runtime source inputs"
	@echo "  check-runtime-provenance - Check the committed runtime source inputs"
	@echo "  check-staged-runtime-xcframework - Validate the staged runtime used by iOS builds"
	@echo "  check-privacy-manifest - Validate the SDK-wide privacy inventory"
	@echo "  check-product-neutrality - Reject Editor-product-specific SDK support"
	@echo "  test-product-neutrality - Prove the product-neutrality guard fails closed"
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

check-product-neutrality:
	@scripts/check-product-neutrality.sh

test-product-neutrality:
	@scripts/test-check-product-neutrality.sh

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
build-runtime-xcframework:
	@scripts/build-runtime-xcframework.sh

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

# CI and clean-room qualification unpack the same archive declared by
# Package.swift, then use the normal staging and validation path.
unpack-runtime-xcframework:
	@set -eu; \
	temporary=$$(mktemp -d); \
	trap 'rm -rf "$$temporary"' EXIT; \
	unpacked="$$temporary/unpacked"; \
	if [ ! -f "$(COMMITTED_RUNTIME_ARCHIVE)" ]; then \
		echo "Committed runtime archive not found: $(COMMITTED_RUNTIME_ARCHIVE)" >&2; \
		exit 1; \
	fi; \
	mkdir -p "$$unpacked"; \
	ditto -x -k "$(COMMITTED_RUNTIME_ARCHIVE)" "$$unpacked"; \
	runtime=$$(find "$$unpacked" -type d -name NuxieRuntime.xcframework -print -quit); \
	if [ -z "$$runtime" ]; then \
		echo "Committed runtime archive does not contain NuxieRuntime.xcframework" >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory stage-runtime-xcframework NUXIE_RUNTIME_XCFRAMEWORK="$$runtime"

package-runtime-xcframework: build-runtime-xcframework
	@set -eu; \
	mkdir -p Runtime; \
	temporary=$$(mktemp -d Runtime/.runtime-package.XXXXXX); \
	trap 'rm -rf "$$temporary"' EXIT; \
	archive="$$temporary/NuxieRuntime.xcframework.zip"; \
	ditto -c -k --sequesterRsrc --keepParent \
		"$(STAGED_RUNTIME_XCFRAMEWORK)" "$$archive"; \
	mv "$$archive" "$(COMMITTED_RUNTIME_ARCHIVE)"
	@$(MAKE) --no-print-directory write-runtime-provenance

write-runtime-provenance:
	@set -eu; \
	mkdir -p Runtime; \
	runtime_revision=$$(git -C third_party/nuxie-runtime rev-parse HEAD); \
	apple_source_hash=$$(git rev-parse HEAD:native/nux-apple-runtime); \
	temporary=$$(mktemp Runtime/.provenance.XXXXXX); \
	trap 'rm -f "$$temporary"' EXIT; \
	printf '{\n  "nuxieRuntimeRevision": "%s",\n  "appleRuntimeSourceHash": "%s"\n}\n' \
		"$$runtime_revision" "$$apple_source_hash" > "$$temporary"; \
	mv "$$temporary" "$(RUNTIME_PROVENANCE)"; \
	trap - EXIT; \
	echo "Wrote $(RUNTIME_PROVENANCE)"

# Reads the recorded submodule gitlink rather than the checked-out submodule, so
# the guard needs no submodule clone. write-runtime-provenance records the engine
# the artifact was actually built from, so a mismatch here also catches an
# artifact built against an engine state this repo does not record.
check-runtime-provenance:
	@set -eu; \
	current_runtime=$$(git rev-parse HEAD:third_party/nuxie-runtime); \
	current_apple=$$(git rev-parse HEAD:native/nux-apple-runtime); \
	recorded_runtime=$$(sed -n 's/^[[:space:]]*"nuxieRuntimeRevision": "\([0-9a-f][0-9a-f]*\)".*$$/\1/p' "$(RUNTIME_PROVENANCE)" 2>/dev/null || true); \
	recorded_apple=$$(sed -n 's/^[[:space:]]*"appleRuntimeSourceHash": "\([0-9a-f][0-9a-f]*\)".*$$/\1/p' "$(RUNTIME_PROVENANCE)" 2>/dev/null || true); \
	status=0; \
	if [ "$$recorded_runtime" != "$$current_runtime" ]; then \
		[ -n "$$recorded_runtime" ] || recorded_runtime="<missing>"; \
		echo "nuxieRuntimeRevision mismatch: expected (Runtime/provenance.json) $$recorded_runtime; actual (current checkout) $$current_runtime" >&2; \
		status=1; \
	fi; \
	if [ "$$recorded_apple" != "$$current_apple" ]; then \
		[ -n "$$recorded_apple" ] || recorded_apple="<missing>"; \
		echo "appleRuntimeSourceHash mismatch: expected (Runtime/provenance.json) $$recorded_apple; actual (current checkout) $$current_apple" >&2; \
		status=1; \
	fi; \
	exit $$status

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

test-runtime-adapter: check-staged-runtime-xcframework
	@$(MAKE) test-unit XCODEBUILD_TEST_FLAGS='-quiet -only-testing:NuxieSDKUnitTests/NuxieRuntimeAdapterTests -only-testing:NuxieSDKUnitTests/NuxieRuntimeFixtureTraceTests -only-testing:NuxieSDKUnitTests/NuxieRuntimeNativeResultSeamTests -only-testing:NuxieSDKUnitTests/ExperienceRuntimeStateBridgeTests'

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

test-experience-runtime-ui: check-staged-runtime-xcframework generate
	@echo "Running signed package runtime UI tests on iOS Simulator..."
	@TEST_DESTINATION='$(TEST_DESTINATION)' \
		TEST_SIMULATOR_NAME='$(TEST_SIMULATOR_NAME)' \
		TEST_SIMULATOR_OS='$(TEST_SIMULATOR_OS)' \
		SCHEME_EXPERIENCE_RUNTIME_UI='$(SCHEME_EXPERIENCE_RUNTIME_UI)' \
		scripts/run-experience-runtime-ui-tests.sh

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
	@echo "Building signed package runtime reference app..."
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
