#!/usr/bin/env bash

set -euo pipefail

xcodebuild_bin="${NUXIE_XCODEBUILD_BIN:-xcodebuild}"
diagnostics_dir="${NUXIE_MACOS_TEST_DIAGNOSTICS_DIR:-macos-unit-crash-reports}"
retry_delay_seconds="${NUXIE_MACOS_TEST_RETRY_DELAY_SECONDS:-10}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-macos-unit.XXXXXX")"
first_log="$temporary_dir/first-attempt.log"
retry_log="$temporary_dir/retry-attempt.log"
trap 'rm -rf "$temporary_dir"' EXIT

run_xcodebuild() {
  local action="$1"
  local log_path="$2"
  shift 2

  set +e
  "$xcodebuild_bin" "$action" "$@" 2>&1 | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

if run_xcodebuild test "$first_log" "$@"; then
  exit 0
else
  first_status="$?"
fi

testmanagerd_failure='com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 3 - No such process'
if ! grep -Fq "$testmanagerd_failure" "$first_log"; then
  exit "$first_status"
fi

mkdir -p "$diagnostics_dir"
cp "$first_log" "$diagnostics_dir/testmanagerd-first-attempt.log"
echo "macOS XCTest lost the host testmanagerd service; retrying the already-built tests once."
sleep "$retry_delay_seconds"

if run_xcodebuild test-without-building "$retry_log" "$@"; then
  exit 0
else
  retry_status="$?"
fi

cp "$retry_log" "$diagnostics_dir/testmanagerd-retry-attempt.log"
exit "$retry_status"
