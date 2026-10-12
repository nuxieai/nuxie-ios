#!/usr/bin/env bash
# Source in standalone Buildkite lanes to share the root/runtime cache policy.
nuxie_bazel_ci_caches() {
  if [[ "${NUXIE_CI_RUNNER_POLICY_VERSION:-1}" == 2 ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci/runner-policy.sh"
    nuxie_runner_policy_environment || return
    export NODE_OPTIONS="${NUXIE_NODE_OPTIONS}"
    return
  fi
  local agent_name cache_root
  agent_name="$(printf '%s' "${BUILDKITE_AGENT_NAME:-${RUNNER_NAME:-}}" | sed 's/[^A-Za-z0-9._-]/-/g')"
  [[ -n "$agent_name" && "$agent_name" != "." && "$agent_name" != ".." ]] || agent_name=default
  cache_root="$HOME/.nuxie-ci/editor-cargo-target/$agent_name"
  export BAZELISK_HOME="${BAZELISK_HOME-$cache_root/bazelisk}"
  export NUXIE_BAZEL_OUTPUT_USER_ROOT="${NUXIE_BAZEL_OUTPUT_USER_ROOT-$cache_root/bazel}"
  export NUXIE_BAZEL_CACHE_DIR="${NUXIE_BAZEL_CACHE_DIR-$cache_root/bazel-shared-cache}"
  export NUXIE_BAZEL_BATCH="${NUXIE_BAZEL_BATCH-1}"
}
nuxie_bazel_ci_caches
