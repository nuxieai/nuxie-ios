#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT

assert_failed_prerequisite_cleans_sentinels() {
    local target="$1"
    shift

    local artifact_root="${temporary}/${target}"
    local log_path="${temporary}/${target}.log"
    mkdir -p "${artifact_root}"

    local sentinel
    for sentinel in "$@"; do
        touch "${artifact_root}/${sentinel}"
    done

    if make \
        --no-print-directory \
        -C "${repository_root}" \
        "${target}" \
        NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR="${artifact_root}" \
        RUNTIME_ARTIFACTS_DIR="${temporary}/runtime-artifacts" \
        RUNTIME_RELEASE_URL="file://${temporary}/missing-runtime.zip" \
        RUNTIME_RELEASE_CHECKSUM=invalid \
        >"${log_path}" 2>&1; then
        echo "${target} unexpectedly passed its injected prerequisite failure" >&2
        exit 1
    fi

    for sentinel in "$@"; do
        if [[ -e "${artifact_root}/${sentinel}" ]]; then
            echo "${target} left a stale ${sentinel} after prerequisite failure" >&2
            sed 's/^/  /' "${log_path}" >&2
            exit 1
        fi
    done
}

assert_failed_prerequisite_cleans_sentinels \
    test-editor-next-production-artifact \
    ios-native-consumed.ok \
    ios-sdk-pipeline-consumed.ok
assert_failed_prerequisite_cleans_sentinels \
    test-editor-next-native-pixels \
    ios-gpu-canvas-pixels.ok \
    ios-native-corpus-pixels.ok
assert_failed_prerequisite_cleans_sentinels \
    test-editor-next-native-archive \
    ios-native-runtime-archive.ok

unit_test_path="${repository_root}/Tests/NuxieUnitTests/Experiences/EditorNextNativeArtifactTests.swift"
if grep -Eq 'ios-(native|sdk-pipeline)-consumed\.ok|write(Native)?ConsumerSentinel' \
    "${unit_test_path}"; then
    echo "EditorNextNativeArtifactTests must not write overall-success sentinels" >&2
    exit 1
fi

echo "Editor Next artifact sentinels fail closed across prerequisite failures"
