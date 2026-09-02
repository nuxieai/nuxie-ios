#!/usr/bin/env bash

set -euo pipefail

xcodebuild_bin="${NUXIE_XCODEBUILD_BIN:-xcodebuild}"
launchctl_bin="${NUXIE_LAUNCHCTL_BIN:-launchctl}"
kill_bin="${NUXIE_KILL_BIN:-kill}"
ps_bin="${NUXIE_PS_BIN:-ps}"
diagnostics_dir="${NUXIE_MACOS_TEST_DIAGNOSTICS_DIR:-macos-unit-crash-reports}"
retry_delay_seconds="${NUXIE_MACOS_TEST_RETRY_DELAY_SECONDS:-10}"
testmanagerd_uid="${NUXIE_TESTMANAGERD_UID:-$(id -u)}"
testmanagerd_service="${NUXIE_TESTMANAGERD_SERVICE:-gui/$testmanagerd_uid/com.apple.testmanagerd}"
testmanagerd_process_path="${NUXIE_TESTMANAGERD_PROCESS_PATH:-/usr/libexec/testmanagerd}"
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

testmanagerd_pid_from_snapshot() {
  sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1
}

testmanagerd_pid_from_process_table() {
  "$ps_bin" -axo uid=,pid=,command= | awk \
    -v uid="$testmanagerd_uid" \
    -v process_path="$testmanagerd_process_path" \
    '$1 == uid && $3 == process_path && NF == 3 { print $2; exit }'
}

testmanagerd_snapshot_is_ready() {
  local snapshot="$1"
  grep -Fq 'state = running' <<<"$snapshot" \
    && awk '
      /"com.apple.testmanagerd.control" = \{/ { in_control_endpoint = 1; next }
      in_control_endpoint && /active = 1/ { found = 1; exit }
      in_control_endpoint && /^[[:space:]]*}/ { exit }
      END { exit found ? 0 : 1 }
    ' <<<"$snapshot"
}

restore_testmanagerd() {
  local service_snapshot
  service_snapshot="$("$launchctl_bin" print "$testmanagerd_service" 2>/dev/null || true)"
  local current_pid
  current_pid="$(testmanagerd_pid_from_snapshot <<<"$service_snapshot")"
  if [[ -z "$current_pid" ]]; then
    # A broken control channel can make the per-service launchctl snapshot
    # transiently empty while its stale user-owned process is still alive.
    current_pid="$(testmanagerd_pid_from_process_table)"
  fi

  if [[ -n "$current_pid" ]]; then
    if ! "$kill_bin" -TERM "$current_pid"; then
      echo "Unable to stop the stale macOS XCTest host service process." >&2
      return 1
    fi

    local stop_deadline=$((SECONDS + testmanagerd_restore_timeout_seconds))
    while ((SECONDS <= stop_deadline)); do
      local observed_pid
      service_snapshot="$("$launchctl_bin" print "$testmanagerd_service" 2>/dev/null || true)"
      observed_pid="$(testmanagerd_pid_from_snapshot <<<"$service_snapshot")"
      if [[ "$observed_pid" != "$current_pid" ]]; then
        break
      fi
      sleep "$testmanagerd_restore_poll_seconds"
    done

    if [[ "$observed_pid" == "$current_pid" ]]; then
      echo "The stale macOS XCTest host service did not stop before the recovery deadline." >&2
      return 1
    fi
  fi

  # SIP prevents an unprivileged agent from using `launchctl kickstart -k` on
  # this Apple launch agent. Once its user-owned process has stopped, a plain
  # kickstart is permitted and asks launchd to create a fresh process.
  if ! "$launchctl_bin" kickstart "$testmanagerd_service"; then
    echo "Unable to restart the macOS XCTest host service." >&2
    return 1
  fi

  local deadline=$((SECONDS + testmanagerd_restore_timeout_seconds))
  while ((SECONDS <= deadline)); do
    service_snapshot="$("$launchctl_bin" print "$testmanagerd_service" 2>/dev/null || true)"
    local restored_pid
    restored_pid="$(testmanagerd_pid_from_snapshot <<<"$service_snapshot")"
    if [[ -n "$restored_pid" && "$restored_pid" != "$current_pid" ]] \
      && testmanagerd_snapshot_is_ready "$service_snapshot"; then
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
