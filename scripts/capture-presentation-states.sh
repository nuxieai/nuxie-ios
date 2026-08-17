#!/usr/bin/env bash
# Captures the presentation-state filmstrip from a booted simulator.
#
# Each capture launches the host app straight into one scenario/condition,
# waits for the state to settle, and writes a PNG. Runs are independent so a
# stalled or failed state cannot leak into the next one.
#
# Usage:
#   scripts/capture-presentation-states.sh <output-dir> [simulator-udid]
#
# Requires the host app to be built and installed first, e.g.
#   xcodebuild -project NuxieSDK.xcodeproj -scheme NuxieExperienceRuntimeHostApp \
#     -destination "platform=iOS Simulator,id=<udid>" -derivedDataPath <dd> build
#   xcrun simctl install <udid> <dd>/Build/Products/Debug-iphonesimulator/NuxieExperienceRuntimeHost.app

set -euo pipefail

OUTPUT_DIR="${1:?usage: capture-presentation-states.sh <output-dir> [simulator-udid]}"
UDID="${2:-booted}"
BUNDLE_ID="com.nuxie.sdk.experience-runtime-host"

mkdir -p "$OUTPUT_DIR"

# scenario:condition:settle-seconds:label
#
# `slow` settles past the 5 s recovery-affordance delay; `normal` and `warm`
# only need enough time to reach a revealed drawable.
CAPTURES=(
  "full-screen-dark:normal:5:01-fullscreen-dark-revealed"
  "full-screen-dark:slow:4:02-fullscreen-dark-loading"
  "full-screen-dark:failure:9:03-fullscreen-dark-recovery"
  "full-screen-light:slow:4:04-fullscreen-light-loading"
  "full-screen-light:failure:9:05-fullscreen-light-recovery"
  "full-screen-midtone:slow:4:06-fullscreen-midtone-loading"
  "full-screen-midtone:failure:9:07-fullscreen-midtone-recovery"
  "sheet-large:slow:4:08-sheet-large-loading"
  "sheet-large:failure:9:09-sheet-large-recovery"
  "sheet-medium:slow:4:10-sheet-medium-loading"
  "sheet-non-dismissible:slow:4:11-sheet-non-dismissible-loading"
  "drawer-bottom:slow:4:12-drawer-bottom-loading"
  "drawer-bottom:failure:9:13-drawer-bottom-recovery"
  "drawer-trailing:slow:4:14-drawer-trailing-loading"
  "full-screen-dark:warm:5:15-fullscreen-dark-warm"
)

for capture in "${CAPTURES[@]}"; do
  IFS=':' read -r scenario condition settle label <<<"$capture"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    --nuxie-presentation-state "$scenario" \
    --nuxie-presentation-condition "$condition" >/dev/null
  sleep "$settle"
  xcrun simctl io "$UDID" screenshot "$OUTPUT_DIR/$label.png" >/dev/null 2>&1
  echo "captured $label ($scenario / $condition)"
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "Wrote $((${#CAPTURES[@]})) captures to $OUTPUT_DIR"
