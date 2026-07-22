#!/usr/bin/env bash
# Strict-concurrency warning ratchet (cleanup P10, Swift 6 compatibility).
#
# The SDK stays in Swift 5 language mode with SWIFT_STRICT_CONCURRENCY=complete
# (project.yml), so data-race violations surface as warnings, not errors. This
# gate keeps that warning count at the committed baseline (0) so the surface
# stays consumable by apps compiled in Swift 6 language mode.
#
# A CLEAN build is required: incremental builds skip unchanged files and hide
# their warnings, so we always build into a scratch DerivedData directory.
#
# Usage: check-concurrency-warnings.sh <xcodeproj> <scheme> <derived-data-dir> <baseline>
set -euo pipefail

PROJECT=${1:?xcodeproj path}
SCHEME=${2:?scheme}
DERIVED_DATA=${3:?derived data dir}
BASELINE=${4:?baseline warning count}

LOG=$(mktemp -t nuxie-concurrency-warnings)
trap 'rm -f "$LOG"' EXIT

echo "Clean-building $SCHEME (strict concurrency: complete) ..."
rm -rf "$DERIVED_DATA"
if ! xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  >"$LOG" 2>&1; then
  echo "Build failed; last 50 log lines:" >&2
  tail -50 "$LOG" >&2
  exit 1
fi

# Compiler warnings from our sources only (unique sites), minus infra noise
# (linker version notes, xcodebuild project-group chatter, AppIntents).
WARNINGS=$(grep "warning:" "$LOG" \
  | grep -v "ld: warning:\|appintentsmetadataprocessor\|member of multiple groups\|AppIntents" \
  | sort -u || true)

# Strict-concurrency subset: everything Swift 6 language mode would reject.
CONCURRENCY_WARNINGS=$(printf '%s\n' "$WARNINGS" \
  | grep -E "Swift 6 language mode|Sendable|sending |actor-isolated|isolat|concurrency|data races|concurrently-executing|asynchronous context" || true)

TOTAL_COUNT=$(printf '%s' "$WARNINGS" | grep -c . || true)
CONCURRENCY_COUNT=$(printf '%s' "$CONCURRENCY_WARNINGS" | grep -c . || true)

echo "Compiler warnings (unique): $TOTAL_COUNT"
echo "Strict-concurrency warnings (unique): $CONCURRENCY_COUNT (baseline: $BASELINE)"

if [ "$CONCURRENCY_COUNT" -gt "$BASELINE" ]; then
  echo "" >&2
  echo "FAIL: strict-concurrency warnings exceed the committed baseline." >&2
  echo "Fix the new warnings (do not raise the baseline):" >&2
  printf '%s\n' "$CONCURRENCY_WARNINGS" >&2
  exit 1
fi

echo "OK: strict-concurrency warning count is at or below the baseline."
