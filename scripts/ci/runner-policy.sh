#!/usr/bin/env bash
# Root-owned installed policy is independent of job HOME/PATH and checkout code.

nuxie_runner_policy_paths() {
  case "$(/usr/bin/uname -s)" in
    Darwin)
      NUXIE_RUNNER_POLICY_HELPER=/Library/NuxieBuildkite/hooks/runner-policy.py
      NUXIE_RUNNER_POLICY_FILE=/Library/NuxieBuildkite/runner-policy.json
      ;;
    Linux)
      NUXIE_RUNNER_POLICY_HELPER=/usr/local/lib/nuxie-buildkite/hooks/runner-policy.py
      NUXIE_RUNNER_POLICY_FILE=/etc/nuxie/buildkite-runner-policy.json
      ;;
    *) echo "Unsupported runner policy platform" >&2; return 1 ;;
  esac
}

nuxie_runner_policy_verify() {
  nuxie_runner_policy_paths || return
  /usr/bin/python3 -I - "${NUXIE_RUNNER_POLICY_HELPER}" "${NUXIE_RUNNER_POLICY_FILE}" <<'PY'
import pathlib
import stat
import sys

try:
    for argument in sys.argv[1:]:
        path = pathlib.Path(argument)
        for component in reversed([path, *path.parents]):
            metadata = component.lstat()
            if metadata.st_uid != 0 or metadata.st_mode & 0o022 or stat.S_ISLNK(metadata.st_mode):
                raise ValueError("installed runner policy/helper must have a root-controlled path: " + str(component))
        if not path.is_file():
            raise ValueError("installed runner policy/helper must be regular files")
except (OSError, ValueError) as error:
    sys.stderr.write("Runner policy trust check failed: " + str(error) + "\n")
    sys.exit(1)
PY
}

nuxie_runner_policy_environment() {
  local selected_environment
  nuxie_runner_policy_verify || return
  selected_environment="$(/usr/bin/python3 -I "${NUXIE_RUNNER_POLICY_HELPER}" environment)" || return
  eval "${selected_environment}"
}
