#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-macos-unit-test.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

fake_xcodebuild="$temporary_dir/xcodebuild"
calls_file="$temporary_dir/calls"
state_file="$temporary_dir/state"
diagnostics_dir="$temporary_dir/diagnostics"

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

run_case() {
  local scenario="$1"
  : >"$calls_file"
  rm -f "$state_file"
  rm -rf "$diagnostics_dir"
  NUXIE_XCODEBUILD_BIN="$fake_xcodebuild" \
    NUXIE_MACOS_TEST_DIAGNOSTICS_DIR="$diagnostics_dir" \
    NUXIE_MACOS_TEST_RETRY_DELAY_SECONDS=0 \
    NUXIE_TEST_CALLS_FILE="$calls_file" \
    NUXIE_TEST_STATE_FILE="$state_file" \
    NUXIE_TEST_SCENARIO="$scenario" \
    "$root_dir/scripts/run-macos-unit-tests.sh" -project Example.xcodeproj
}

run_case success
[[ "$(cat "$calls_file")" == "test" ]]

set +e
run_case ordinary_failure
ordinary_status="$?"
set -e
[[ "$ordinary_status" == "42" ]]
[[ "$(cat "$calls_file")" == "test" ]]

run_case testmanagerd_then_success
[[ "$(cat "$calls_file")" == $'test\ntest-without-building' ]]
[[ -f "$diagnostics_dir/testmanagerd-first-attempt.log" ]]

echo "macOS unit-test runner recovery checks passed"
