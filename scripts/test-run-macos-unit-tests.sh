#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-macos-unit-test.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

fake_xcodebuild="$temporary_dir/xcodebuild"
calls_file="$temporary_dir/calls"
state_file="$temporary_dir/state"
diagnostics_dir="$temporary_dir/diagnostics"
launchctl_calls_file="$temporary_dir/launchctl-calls"

cat >"$fake_xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$NUXIE_TEST_CALLS_FILE"
case "$NUXIE_TEST_SCENARIO" in
  success)
    exit 0
    ;;
  ordinary_failure)
    echo "Testing failed: an assertion failed" >&2
    exit 42
    ;;
  testmanagerd_then_success)
    if [[ ! -f "$NUXIE_TEST_STATE_FILE" ]]; then
      : >"$NUXIE_TEST_STATE_FILE"
      echo "The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 3 - No such process" >&2
      exit 65
    fi
    exit 0
    ;;
esac
echo "unknown test scenario" >&2
exit 64
SH
chmod +x "$fake_xcodebuild"

fake_launchctl="$temporary_dir/launchctl"
cat >"$fake_launchctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NUXIE_TEST_LAUNCHCTL_CALLS_FILE"
case "$1" in
  kickstart)
    exit 0
    ;;
  print)
    echo "state = running"
    exit 0
    ;;
esac
exit 64
SH
chmod +x "$fake_launchctl"

run_case() {
  local scenario="$1"
  : >"$calls_file"
  : >"$launchctl_calls_file"
  rm -f "$state_file"
  rm -rf "$diagnostics_dir"
  NUXIE_XCODEBUILD_BIN="$fake_xcodebuild" \
    NUXIE_LAUNCHCTL_BIN="$fake_launchctl" \
    NUXIE_MACOS_TEST_DIAGNOSTICS_DIR="$diagnostics_dir" \
    NUXIE_MACOS_TEST_RETRY_DELAY_SECONDS=0 \
    NUXIE_TESTMANAGERD_SERVICE="gui/501/com.apple.testmanagerd" \
    NUXIE_TESTMANAGERD_RESTORE_TIMEOUT_SECONDS=0 \
    NUXIE_TESTMANAGERD_RESTORE_POLL_SECONDS=0 \
    NUXIE_TEST_CALLS_FILE="$calls_file" \
    NUXIE_TEST_LAUNCHCTL_CALLS_FILE="$launchctl_calls_file" \
    NUXIE_TEST_STATE_FILE="$state_file" \
    NUXIE_TEST_SCENARIO="$scenario" \
    "$root_dir/scripts/run-macos-unit-tests.sh" -project Example.xcodeproj
}

run_case success
[[ "$(cat "$calls_file")" == "test" ]]
[[ ! -s "$launchctl_calls_file" ]]

set +e
run_case ordinary_failure
ordinary_status="$?"
set -e
[[ "$ordinary_status" == "42" ]]
[[ "$(cat "$calls_file")" == "test" ]]
[[ ! -s "$launchctl_calls_file" ]]

run_case testmanagerd_then_success
[[ "$(cat "$calls_file")" == $'test\ntest-without-building' ]]
[[ "$(cat "$launchctl_calls_file")" == $'kickstart -k gui/501/com.apple.testmanagerd\nprint gui/501/com.apple.testmanagerd' ]]
[[ -f "$diagnostics_dir/testmanagerd-first-attempt.log" ]]

echo "macOS unit-test runner recovery checks passed"
