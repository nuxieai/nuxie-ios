#!/usr/bin/env bash

set -euo pipefail

xcodebuild_bin="${NUXIE_XCODEBUILD_BIN:-xcodebuild}"
launchctl_bin="${NUXIE_LAUNCHCTL_BIN:-launchctl}"
diagnostics_dir="${NUXIE_MACOS_TEST_DIAGNOSTICS_DIR:-macos-unit-crash-reports}"
retry_delay_seconds="${NUXIE_MACOS_TEST_RETRY_DELAY_SECONDS:-10}"
testmanagerd_service="${NUXIE_TESTMANAGERD_SERVICE:-gui/$(id -u)/com.apple.testmanagerd}"
testmanagerd_restore_timeout_seconds="${NUXIE_TESTMANAGERD_RESTORE_TIMEOUT_SECONDS:-30}"
testmanagerd_restore_poll_seconds="${NUXIE_TESTMANAGERD_RESTORE_POLL_SECONDS:-1}"
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

restore_testmanagerd() {
  if ! "$launchctl_bin" kickstart -k "$testmanagerd_service"; then
    echo "Unable to restart the macOS XCTest host service." >&2
    return 1
  fi

  local deadline=$((SECONDS + testmanagerd_restore_timeout_seconds))
  while ((SECONDS <= deadline)); do
    if "$launchctl_bin" print "$testmanagerd_service" 2>/dev/null | grep -Fq 'state = running'; then
      return 0
    fi
    sleep "$testmanagerd_restore_poll_seconds"
  done

  echo "The macOS XCTest host service did not become ready before the recovery deadline." >&2
  return 1
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
echo "macOS XCTest lost the host testmanagerd service; restarting it before retrying the already-built tests."
if ! restore_testmanagerd; then
  exit "$first_status"
fi
sleep "$retry_delay_seconds"

if run_xcodebuild test-without-building "$retry_log" "$@"; then
  exit 0
else
  retry_status="$?"
fi

cp "$retry_log" "$diagnostics_dir/testmanagerd-retry-attempt.log"
exit "$retry_status"
