#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
scheme="${SCHEME_EXPERIENCE_RUNTIME_UI:-NuxieExperienceRuntimeUITests}"
destination="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
result_directory="${NUXIE_EXPERIENCE_RUNTIME_OUTPUT_DIR:-${repository_root}/test-results/experience-runtime}"
result_bundle="${result_directory}/ExperienceRuntimeUITests.xcresult"

mkdir -p "${result_directory}"
if [[ -e "${result_bundle}" ]]; then
    rm -rf "${result_bundle}"
fi

xcodebuild test \
    -project "${repository_root}/NuxieSDK.xcodeproj" \
    -scheme "${scheme}" \
    -configuration Debug \
    -destination "${destination}" \
    -resultBundlePath "${result_bundle}"

echo "Experience runtime UI result: ${result_bundle}"
