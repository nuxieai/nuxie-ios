#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-macos-unit-test.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

fake_xcodebuild="$temporary_dir/xcodebuild"
fake_xcrun="$temporary_dir/xcrun"
calls_file="$temporary_dir/xcodebuild-calls"
xcrun_calls_file="$temporary_dir/xcrun-calls"
diagnostics_dir="$temporary_dir/diagnostics"
derived_data_path="$temporary_dir/DerivedData"
test_bundle_path="$derived_data_path/Build/Products/Debug/NuxieSDKMacUnitTests.xctest"

cat >"$fake_xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NUXIE_TEST_XCODEBUILD_CALLS_FILE"
case "$NUXIE_TEST_SCENARIO" in
  success)
    exit 0
    ;;
  ordinary_failure)
    echo "Testing failed: an assertion failed" >&2
    exit 42
    ;;
  testmanagerd_failure)
    echo "The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 3 - No such process" >&2
    exit 65
    ;;
esac
echo "unknown test scenario" >&2
exit 64
SH
chmod +x "$fake_xcodebuild"

cat >"$fake_xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NUXIE_TEST_XCRUN_CALLS_FILE"
if [[ "$NUXIE_TEST_XCTEST_SCENARIO" == "failure" ]]; then
  echo "Executed 1 test, with 1 failure" >&2
  exit 73
fi
echo "Executed 1419 tests, with 0 failures"
SH
chmod +x "$fake_xcrun"

run_case() {
  local scenario="$1"
  local xctest_scenario="${2:-success}"
  local bundle_state="${3:-present}"
  shift 3 || true

  : >"$calls_file"
  : >"$xcrun_calls_file"
  rm -rf "$diagnostics_dir" "$derived_data_path"
  if [[ "$bundle_state" == "present" ]]; then
    mkdir -p "$test_bundle_path"
  fi

  NUXIE_XCODEBUILD_BIN="$fake_xcodebuild" \
    NUXIE_XCRUN_BIN="$fake_xcrun" \
    NUXIE_MACOS_TEST_DIAGNOSTICS_DIR="$diagnostics_dir" \
    NUXIE_TEST_XCODEBUILD_CALLS_FILE="$calls_file" \
    NUXIE_TEST_XCRUN_CALLS_FILE="$xcrun_calls_file" \
    NUXIE_TEST_XCTEST_SCENARIO="$xctest_scenario" \
    NUXIE_TEST_SCENARIO="$scenario" \
    "$root_dir/scripts/run-macos-unit-tests.sh" \
      -project Example.xcodeproj \
      -scheme NuxieSDKMacUnitTests \
      -configuration Debug \
      -derivedDataPath "$derived_data_path" \
      -destination platform=macOS \
      "$@"
}

run_case success success present
[[ "$(cat "$calls_file")" == *"test -project Example.xcodeproj"* ]]
[[ ! -s "$xcrun_calls_file" ]]

set +e
run_case ordinary_failure success present
ordinary_status="$?"
set -e
[[ "$ordinary_status" == "42" ]]
[[ ! -s "$xcrun_calls_file" ]]

run_case testmanagerd_failure success present
[[ "$(cat "$xcrun_calls_file")" == "xctest $test_bundle_path" ]]
[[ -f "$diagnostics_dir/testmanagerd-xcodebuild-attempt.log" ]]
[[ ! -f "$diagnostics_dir/testmanagerd-xctest-fallback.log" ]]

run_case testmanagerd_failure success present \
  -only-testing:NuxieSDKMacUnitTests/AppActionEncodingTests/testEveryAppActionMatchesTheEncodingFixture \
  -only-testing:NuxieSDKMacUnitTests/ValueRefResolverTests/parseRefPath
[[ "$(cat "$xcrun_calls_file")" == "xctest -XCTest AppActionEncodingTests/testEveryAppActionMatchesTheEncodingFixture,ValueRefResolverTests/parseRefPath $test_bundle_path" ]]

set +e
run_case testmanagerd_failure failure present
xctest_failure_status="$?"
set -e
[[ "$xctest_failure_status" == "73" ]]
[[ -f "$diagnostics_dir/testmanagerd-xcodebuild-attempt.log" ]]
[[ -f "$diagnostics_dir/testmanagerd-xctest-fallback.log" ]]

set +e
run_case testmanagerd_failure success missing
missing_bundle_status="$?"
set -e
[[ "$missing_bundle_status" == "65" ]]
[[ ! -s "$xcrun_calls_file" ]]

set +e
run_case testmanagerd_failure success present -skip-testing:NuxieSDKMacUnitTests/ValueRefResolverTests
unsupported_selector_status="$?"
set -e
[[ "$unsupported_selector_status" == "65" ]]
[[ ! -s "$xcrun_calls_file" ]]

echo "macOS unit-test runner fallback checks passed"
