#!/usr/bin/env bash
# Source this file from the common launcher before appending command arguments.
NUXIE_BAZEL_REMOTE_ARGS=()
nuxie_bazel_remote_options="$(python3 "$(dirname "${BASH_SOURCE[0]}")/remote-cache.py" flags)" || return 1
if [[ -n "$nuxie_bazel_remote_options" ]]; then
  while IFS= read -r nuxie_bazel_remote_option; do
    NUXIE_BAZEL_REMOTE_ARGS+=("$nuxie_bazel_remote_option")
  done <<< "$nuxie_bazel_remote_options"
fi
unset nuxie_bazel_remote_options nuxie_bazel_remote_option
