#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ "${NUXIE_CI_RUNNER_POLICY_VERSION:-1}" == 2 ]]; then
  source "${ROOT_DIR}/scripts/ci/runner-policy.sh"
  nuxie_runner_policy_environment || exit 1
fi

if [[ -n "${NUXIE_BAZEL_BIN:-}" ]]; then
  bazel_bin="$NUXIE_BAZEL_BIN"
elif [[ -x "$ROOT_DIR/node_modules/.bin/bazelisk" ]]; then
  bazel_bin="$ROOT_DIR/node_modules/.bin/bazelisk"
elif command -v bazelisk >/dev/null 2>&1; then
  bazel_bin="$(command -v bazelisk)"
elif command -v bazel >/dev/null 2>&1; then
  bazel_bin="$(command -v bazel)"
else
  bazel_bin="$ROOT_DIR/scripts/bazel/launcher.py"
fi

startup_args=(--nosystem_rc --nohome_rc)
if [[ -n "${NUXIE_BAZEL_CACHE_DIR+x}" ]]; then
  cache_options="$(python3 "$ROOT_DIR/scripts/bazel/cache.py")"
  startup_args+=("$cache_options")
fi
if [[ "${NUXIE_BAZEL_BATCH:-${CI:-0}}" == "1" ]]; then
  startup_args+=("--batch")
fi
if [[ -n "${NUXIE_BAZEL_OUTPUT_USER_ROOT:-}" ]]; then
  if [[ "$NUXIE_BAZEL_OUTPUT_USER_ROOT" != /* ]]; then
    echo "NUXIE_BAZEL_OUTPUT_USER_ROOT must be an absolute path" >&2
    exit 1
  fi
  startup_args+=("--output_user_root=$NUXIE_BAZEL_OUTPUT_USER_ROOT")
fi
command="${1:?Expected Bazel command}"
shift
if [[ "${NUXIE_CI_RUNNER_POLICY_VERSION:-1}" == 2 ]]; then
  case "${command}" in
    build|test|run|cquery|aquery|query|info|clean|shutdown|version|help|fetch|sync) ;;
    *) echo "Installed runner policy requires an explicit supported Bazel command" >&2; exit 1 ;;
  esac
fi
command_args=()
case "$command" in
  build|test|run|cquery|aquery)
    if [[ -n "${NUXIE_BAZEL_JOBS:-}" ]]; then
      if [[ ! "$NUXIE_BAZEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "NUXIE_BAZEL_JOBS must be a positive integer" >&2
        exit 1
      fi
      command_args+=("--jobs=$NUXIE_BAZEL_JOBS")
    fi
    for resource in CPU MEMORY LOCAL_TEST_JOBS; do
      variable="NUXIE_BAZEL_${resource}"
      value="${!variable:-}"
      [[ -n "${value}" ]] || continue
      [[ "${value}" =~ ^[1-9][0-9]*$ ]] || { echo "${variable} must be a positive integer" >&2; exit 1; }
      case "${resource}" in
        CPU) command_args+=("--local_resources=cpu=${value}") ;;
        MEMORY) command_args+=("--local_resources=memory=${value}") ;;
        LOCAL_TEST_JOBS) command_args+=("--local_test_jobs=${value}") ;;
      esac
    done
    if [[ "${NUXIE_CI_RUNNER_POLICY_VERSION:-1}" == 2 ]]; then
      repository_environment_next=0
      for argument in "$@"; do
        [[ "${argument}" != -- ]] || break
        if [[ "${repository_environment_next}" == 1 && "${argument}" == NUXIE_BAZEL_BOOTSTRAP_JOBS* ]]; then
          echo "Bazel resource flags are constrained by installed runner policy" >&2; exit 1
        fi
        repository_environment_next=0
        case "${argument}" in
          --repo_env) repository_environment_next=1 ;;
          --jobs|--jobs=*|-j|-j[0-9]*|--local_resources|--local_resources=*|--local_cpu_resources|--local_cpu_resources=*|--local_ram_resources|--local_ram_resources=*|--local_test_jobs|--local_test_jobs=*|--disk_cache|--disk_cache=*|--repository_cache|--repository_cache=*|--repo_contents_cache|--repo_contents_cache=*|--repo_env=NUXIE_BAZEL_BOOTSTRAP_JOBS|--repo_env=NUXIE_BAZEL_BOOTSTRAP_JOBS=*|--profile|--profile=*|--build_event_json_file|--build_event_json_file=*)
            echo "Bazel resource flags are constrained by installed runner policy" >&2; exit 1 ;;
        esac
      done
      command_args+=("--repo_env=NUXIE_BAZEL_BOOTSTRAP_JOBS=${NUXIE_BAZEL_BOOTSTRAP_JOBS}")
      # Config expansions are caller options too. Force singleton cache paths
      # after them at command-line priority, rather than relying on the rc.
      command_args+=("--repository_cache=${NUXIE_BAZEL_CACHE_DIR}/repositories" "--repo_contents_cache=${NUXIE_BAZEL_CACHE_DIR}/repository-contents" "--disk_cache=${NUXIE_BAZEL_CACHE_DIR}/actions")
      evidence_dir="${ROOT_DIR}/output/pipeline/bazel"
      for evidence_path in "${ROOT_DIR}/output" "${ROOT_DIR}/output/pipeline" "${evidence_dir}"; do
        [[ ! -L "${evidence_path}" ]] || { echo "Refusing symlinked Bazel evidence path" >&2; exit 1; }
      done
      mkdir -p "${evidence_dir}"
      invocation="$(python3 -c 'import uuid; print(uuid.uuid4())')"
      command_args+=("--profile=${evidence_dir}/${invocation}.profile.gz")
      case "${command}" in
        build|test|run) command_args+=("--build_event_json_file=${evidence_dir}/${invocation}.bep.json") ;;
      esac
    fi
    NUXIE_BAZEL_REMOTE_ARGS=()
    if [[ -f "${ROOT_DIR}/scripts/bazel/remote-cache.sh" ]]; then
      source "${ROOT_DIR}/scripts/bazel/remote-cache.sh"
      command_args+=(${NUXIE_BAZEL_REMOTE_ARGS[@]+"${NUXIE_BAZEL_REMOTE_ARGS[@]}"})
    fi
    ;;
esac
if [[ "${NUXIE_CI_RUNNER_POLICY_VERSION:-1}" == 2 ]]; then
  caller_args=()
  program_args=()
  after_separator=0
  for argument in "$@"; do
    if [[ "${after_separator}" == 1 ]]; then
      program_args+=("${argument}")
    elif [[ "${argument}" == -- ]]; then
      after_separator=1
      program_args+=(--)
    else
      caller_args+=("${argument}")
    fi
  done
  exec /usr/bin/python3 -I "${NUXIE_RUNNER_POLICY_HELPER}" run -- "$bazel_bin" ${startup_args[@]+"${startup_args[@]}"} "$command" ${caller_args[@]+"${caller_args[@]}"} ${command_args[@]+"${command_args[@]}"} ${program_args[@]+"${program_args[@]}"}
fi
exec "$bazel_bin" ${startup_args[@]+"${startup_args[@]}"} "$command" ${command_args[@]+"${command_args[@]}"} "$@"
