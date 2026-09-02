#!/usr/bin/env bash

set -euo pipefail

xcodebuild_bin="${NUXIE_XCODEBUILD_BIN:-xcodebuild}"
xcrun_bin="${NUXIE_XCRUN_BIN:-xcrun}"
diagnostics_dir="${NUXIE_MACOS_TEST_DIAGNOSTICS_DIR:-macos-unit-crash-reports}"
test_bundle_name="${NUXIE_MACOS_TEST_BUNDLE_NAME:-NuxieSDKMacUnitTests.xctest}"
test_target_name="${NUXIE_MACOS_TEST_TARGET_NAME:-NuxieSDKMacUnitTests}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-macos-unit.XXXXXX")"
first_log="$temporary_dir/xcodebuild-attempt.log"
fallback_log="$temporary_dir/xctest-fallback.log"
trap 'rm -rf "$temporary_dir"' EXIT

argument_value() {
  local expected_flag="$1"
  shift

  while (($# > 0)); do
    if [[ "$1" == "$expected_flag" && $# -ge 2 ]]; then
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done

  return 1
}

run_and_log() {
  local log_path="$1"
  shift

  set +e
  "$@" 2>&1 | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

if run_and_log "$first_log" "$xcodebuild_bin" test "$@"; then
  exit 0
else
  first_status="$?"
fi

testmanagerd_failure='com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 3 - No such process'
if ! grep -Fq "$testmanagerd_failure" "$first_log"; then
  exit "$first_status"
fi

mkdir -p "$diagnostics_dir"
cp "$first_log" "$diagnostics_dir/testmanagerd-xcodebuild-attempt.log"

derived_data_path="$(argument_value -derivedDataPath "$@" || true)"
configuration="$(argument_value -configuration "$@" || true)"
configuration="${configuration:-Debug}"
if [[ -z "$derived_data_path" ]]; then
  echo "Cannot run the direct XCTest fallback without -derivedDataPath." >&2
  exit "$first_status"
fi

test_bundle_path="$derived_data_path/Build/Products/$configuration/$test_bundle_name"
if [[ ! -d "$test_bundle_path" ]]; then
  echo "Cannot run the direct XCTest fallback because the built test bundle is missing: $test_bundle_path" >&2
  exit "$first_status"
fi

selectors=()
for argument in "$@"; do
  case "$argument" in
    -only-testing:*)
      selector="${argument#-only-testing:}"
      selector="${selector#"$test_target_name"/}"
      selectors+=("$selector")
      ;;
    -skip-testing:*)
      echo "The direct XCTest fallback does not support -skip-testing selectors." >&2
      exit "$first_status"
      ;;
  esac
done

xctest_command=("$xcrun_bin" xctest)
if ((${#selectors[@]} > 0)); then
  selector_list="$(IFS=,; printf '%s' "${selectors[*]}")"
  xctest_command+=(-XCTest "$selector_list")
fi
xctest_command+=("$test_bundle_path")

echo "macOS xcodebuild could not reach its host test service; running the already-built XCTest bundle directly."
if run_and_log "$fallback_log" "${xctest_command[@]}"; then
  exit 0
else
  fallback_status="$?"
fi

cp "$fallback_log" "$diagnostics_dir/testmanagerd-xctest-fallback.log"
exit "$fallback_status"
