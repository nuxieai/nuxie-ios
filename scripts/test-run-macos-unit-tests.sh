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
launchctl_state_file="$temporary_dir/launchctl-state"
kill_calls_file="$temporary_dir/kill-calls"
ps_calls_file="$temporary_dir/ps-calls"

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
  requires_user_domain)
    if [[ "${NUXIE_TEST_IN_USER_DOMAIN:-0}" != "1" ]]; then
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
case "$1" in
  asuser)
    shift 2
    NUXIE_TEST_IN_USER_DOMAIN=1 exec "$@"
    ;;
  kickstart)
    printf '%s\n' "$*" >>"$NUXIE_TEST_LAUNCHCTL_CALLS_FILE"
    if [[ "$NUXIE_TEST_RECOVERY_SCENARIO" == "kickstart_failure" ]]; then
      exit 1
    fi
    printf 'running-new\n' >"$NUXIE_TEST_LAUNCHCTL_STATE_FILE"
    exit 0
    ;;
  print)
    printf '%s\n' "$*" >>"$NUXIE_TEST_LAUNCHCTL_CALLS_FILE"
    state="$(cat "$NUXIE_TEST_LAUNCHCTL_STATE_FILE")"
    print_count="$(grep -c '^print ' "$NUXIE_TEST_LAUNCHCTL_CALLS_FILE")"
    if [[ "$NUXIE_TEST_RECOVERY_SCENARIO" == "missing_initial_snapshot" && "$print_count" == "1" ]]; then
      echo "state = not running"
    elif [[ "$state" == "running-old" ]]; then
      echo "state = running"
      echo "pid = 4242"
      echo '"com.apple.testmanagerd.control" = {'
      echo "active = 1"
      echo "}"
    elif [[ "$state" == "running-new" ]]; then
      echo "state = running"
      echo "pid = 4343"
      echo '"com.apple.testmanagerd.control" = {'
      echo "active = 1"
      echo "}"
    else
      echo "state = not running"
    fi
    exit 0
    ;;
esac
exit 64
SH
chmod +x "$fake_launchctl"

fake_kill="$temporary_dir/kill"
cat >"$fake_kill" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NUXIE_TEST_KILL_CALLS_FILE"
if [[ "$NUXIE_TEST_RECOVERY_SCENARIO" == "kill_failure" ]]; then
  exit 1
fi
printf 'stopped\n' >"$NUXIE_TEST_LAUNCHCTL_STATE_FILE"
SH
chmod +x "$fake_kill"

fake_ps="$temporary_dir/ps"
cat >"$fake_ps" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NUXIE_TEST_PS_CALLS_FILE"
state="$(cat "$NUXIE_TEST_LAUNCHCTL_STATE_FILE")"
if [[ "$state" == "running-old" ]]; then
  echo "501 4242 /usr/libexec/testmanagerd"
elif [[ "$state" == "running-new" ]]; then
  echo "501 4343 /usr/libexec/testmanagerd"
fi
SH
chmod +x "$fake_ps"

run_case() {
  local scenario="$1"
  local recovery_scenario="${2:-success}"
  : >"$calls_file"
  : >"$launchctl_calls_file"
  : >"$kill_calls_file"
  : >"$ps_calls_file"
  printf 'running-old\n' >"$launchctl_state_file"
  rm -f "$state_file"
  rm -rf "$diagnostics_dir"
  NUXIE_XCODEBUILD_BIN="$fake_xcodebuild" \
    NUXIE_LAUNCHCTL_BIN="$fake_launchctl" \
    NUXIE_KILL_BIN="$fake_kill" \
    NUXIE_PS_BIN="$fake_ps" \
    NUXIE_MACOS_TEST_DIAGNOSTICS_DIR="$diagnostics_dir" \
    NUXIE_MACOS_TEST_RETRY_DELAY_SECONDS=0 \
    NUXIE_TESTMANAGERD_SERVICE="gui/501/com.apple.testmanagerd" \
    NUXIE_TESTMANAGERD_UID=501 \
    NUXIE_TESTMANAGERD_RESTORE_TIMEOUT_SECONDS=0 \
    NUXIE_TESTMANAGERD_RESTORE_POLL_SECONDS=0 \
    NUXIE_TEST_CALLS_FILE="$calls_file" \
    NUXIE_TEST_LAUNCHCTL_CALLS_FILE="$launchctl_calls_file" \
    NUXIE_TEST_LAUNCHCTL_STATE_FILE="$launchctl_state_file" \
    NUXIE_TEST_KILL_CALLS_FILE="$kill_calls_file" \
    NUXIE_TEST_PS_CALLS_FILE="$ps_calls_file" \
    NUXIE_TEST_RECOVERY_SCENARIO="$recovery_scenario" \
    NUXIE_TEST_STATE_FILE="$state_file" \
    NUXIE_TEST_SCENARIO="$scenario" \
    "$root_dir/scripts/run-macos-unit-tests.sh" -project Example.xcodeproj
}

run_case success
[[ "$(cat "$calls_file")" == "test" ]]
[[ ! -s "$launchctl_calls_file" ]]
[[ ! -s "$kill_calls_file" ]]
[[ ! -s "$ps_calls_file" ]]

set +e
run_case ordinary_failure
ordinary_status="$?"
set -e
[[ "$ordinary_status" == "42" ]]
[[ "$(cat "$calls_file")" == "test" ]]
[[ ! -s "$launchctl_calls_file" ]]
[[ ! -s "$kill_calls_file" ]]
[[ ! -s "$ps_calls_file" ]]

run_case requires_user_domain
[[ "$(cat "$calls_file")" == "test" ]]
[[ ! -s "$launchctl_calls_file" ]]
[[ ! -s "$kill_calls_file" ]]
[[ ! -s "$ps_calls_file" ]]

set +e
run_case testmanagerd_then_success kill_failure
kill_failure_status="$?"
set -e
[[ "$kill_failure_status" == "65" ]]
[[ "$(cat "$calls_file")" == "test" ]]
[[ "$(cat "$launchctl_calls_file")" == "print gui/501/com.apple.testmanagerd" ]]
[[ "$(cat "$kill_calls_file")" == "-TERM 4242" ]]
[[ ! -s "$ps_calls_file" ]]

set +e
run_case testmanagerd_then_success kickstart_failure
kickstart_failure_status="$?"
set -e
[[ "$kickstart_failure_status" == "65" ]]
[[ "$(cat "$calls_file")" == "test" ]]
[[ "$(cat "$launchctl_calls_file")" == $'print gui/501/com.apple.testmanagerd\nprint gui/501/com.apple.testmanagerd\nkickstart gui/501/com.apple.testmanagerd' ]]
[[ "$(cat "$kill_calls_file")" == "-TERM 4242" ]]
[[ ! -s "$ps_calls_file" ]]

run_case testmanagerd_then_success
[[ "$(cat "$calls_file")" == $'test\ntest-without-building' ]]
[[ "$(cat "$launchctl_calls_file")" == $'print gui/501/com.apple.testmanagerd\nprint gui/501/com.apple.testmanagerd\nkickstart gui/501/com.apple.testmanagerd\nprint gui/501/com.apple.testmanagerd' ]]
[[ "$(cat "$kill_calls_file")" == "-TERM 4242" ]]
[[ ! -s "$ps_calls_file" ]]
[[ -f "$diagnostics_dir/testmanagerd-first-attempt.log" ]]

run_case testmanagerd_then_success missing_initial_snapshot
[[ "$(cat "$calls_file")" == $'test\ntest-without-building' ]]
[[ "$(cat "$launchctl_calls_file")" == $'print gui/501/com.apple.testmanagerd\nprint gui/501/com.apple.testmanagerd\nkickstart gui/501/com.apple.testmanagerd\nprint gui/501/com.apple.testmanagerd' ]]
[[ "$(cat "$kill_calls_file")" == "-TERM 4242" ]]
[[ "$(cat "$ps_calls_file")" == "-axo uid=,pid=,command=" ]]
[[ -f "$diagnostics_dir/testmanagerd-first-attempt.log" ]]

echo "macOS unit-test runner recovery checks passed"
