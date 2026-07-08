#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${NUXIE_FLOW_RUNTIME_OUTPUT_DIR:-$ROOT_DIR/test-results/flow-runtime}"
RESULT_BUNDLES_DIR="$OUTPUT_DIR/result-bundles"
SCREENSHOTS_DIR="$OUTPUT_DIR/screenshots"
VIDEOS_DIR="$OUTPUT_DIR/videos"
DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=${TEST_SIMULATOR_NAME:-iPhone 17 Pro},OS=${TEST_SIMULATOR_OS:-26.4}}"
RETRIES="${NUXIE_FLOW_RUNTIME_UI_RETRIES:-1}"
RESET_EACH_CASE="${NUXIE_FLOW_RUNTIME_UI_RESET_EACH_CASE:-0}"
INCLUDE_ALL_CASES="${NUXIE_FLOW_RUNTIME_UI_INCLUDE_ALL_CASES:-0}"
SMOKE_CASES="${NUXIE_FLOW_RUNTIME_UI_SMOKE_CASES:-scripted-response-set,screen-transition-modal,screen-transition-back-push}"
SIMULATOR_UDID=""

if [[ "$DESTINATION" =~ id=([^,]+) ]]; then
  SIMULATOR_UDID="${BASH_REMATCH[1]}"
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$RESULT_BUNDLES_DIR"
mkdir -p "$SCREENSHOTS_DIR"
mkdir -p "$VIDEOS_DIR"

reset_simulator() {
  if [ -z "$SIMULATOR_UDID" ]; then
    return
  fi

  echo "Resetting simulator $SIMULATOR_UDID..."
  xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl erase "$SIMULATOR_UDID" >/dev/null
  xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null
}

start_recording() {
  local video_file="$1"
  (
    for _ in $(seq 1 120); do
      if [ -n "$SIMULATOR_UDID" ]; then
        if xcrun simctl list devices booted 2>/dev/null | grep -q "$SIMULATOR_UDID"; then
          xcrun simctl io "$SIMULATOR_UDID" recordVideo --codec=h264 "$video_file"
          exit 0
        fi
      elif xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then
        xcrun simctl io booted recordVideo --codec=h264 "$video_file"
        exit 0
      fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
  RECORDER_PID=$!
}

stop_recording() {
  local pid="${1:-}"
  local video_file="${2:-}"
  if [ -z "$pid" ]; then
    return
  fi
  if kill -0 "$pid" 2>/dev/null; then
    if [ -n "$video_file" ]; then
      pkill -INT -f "simctl io .*recordVideo.*$video_file" 2>/dev/null || true
    fi
    kill -INT "$pid" 2>/dev/null || true
    for _ in $(seq 1 5); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      if [ -n "$video_file" ]; then
        pkill -TERM -f "simctl io .*recordVideo.*$video_file" 2>/dev/null || true
      fi
      kill -TERM "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  fi
}

build_for_testing() {
  local command=(
    xcodebuild build-for-testing
    -project NuxieSDK.xcodeproj
    -scheme NuxieFlowRuntimeUITests
    -configuration Debug
    -derivedDataPath DerivedData
    -destination "$DESTINATION"
  )

  if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then
    command+=(-clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH")
  fi

  NUXIE_FLOW_RUNTIME_OUTPUT_DIR="$OUTPUT_DIR" "${command[@]}"
}

run_xcode_test() {
  local result_bundle="$1"
  local test_method="$2"
  shift 2

  local command=(
    xcodebuild test-without-building
    -project NuxieSDK.xcodeproj
    -scheme NuxieFlowRuntimeUITests
    -configuration Debug
    -derivedDataPath DerivedData
    -destination "$DESTINATION"
    -resultBundlePath "$result_bundle"
    -only-testing "NuxieFlowRuntimeUITests/FlowRuntimeSmokeTests/$test_method"
  )

  if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then
    command+=(-clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH")
  fi

  NUXIE_FLOW_RUNTIME_OUTPUT_DIR="$OUTPUT_DIR" "${command[@]}"
}

case_enabled() {
  local slug="$1"
  if [ "$INCLUDE_ALL_CASES" = "1" ]; then
    return 0
  fi

  case ",$SMOKE_CASES," in
    *",$slug,"*) return 0 ;;
    *) return 1 ;;
  esac
}

TEST_CASES=(
  "testPublishedFixturesRenderAndHandleNativeInput|published-fixtures|Published fixtures + native input|Renders layout/font/pressable fixtures and verifies the UIKit text input overlay accepts native typing."
  "testPublishedScriptedPressableWritesResponseFieldThroughJourneyRunner|scripted-response-set|Published scripted Pressable|Taps a published listenerAction Pressable and verifies Nuxie.response.set reaches the journey runner."
  "testTextInputMotionMovesWholeEditableField|text-input-motion|Text input motion|The authored TextInput field moves as a whole, and the UIKit editor overlay tracks the rendered field."
  "testSystemPushTransitionUsesTwoLiveRiveSurfacesUntilCompletion|screen-transition-push|System push|screen_1 starts, screen_2 pushes in as another live Rive surface, then screen_2 becomes current."
  "testSystemModalTransitionReachesDestinationScreen|screen-transition-modal|System modal|UIKit opens screen_2 as a native sheet modal with its own live Rive surface."
  "testSystemModalSwipeDismissReturnsToPresentingScreen|screen-transition-modal-dismissible|System modal dismissal|A native sheet swipe dismisses screen_2, reports screen_dismissed, and returns the journey to screen_1."
  "testBackTransitionReturnsWithPushPayload|screen-transition-back-push|Back transition|screen_2 auto-runs a back action and returns to screen_1 with the push payload."
  "testReduceMotionFallsBackToImmediateReplacement|screen-transition-reduce-motion|Reduce motion|An authored fade is skipped when reduce motion is forced."
  "testTextInputOverlayRebindsAfterBackTransition|text-input-rebound|Text input rebound|A static UIKit text input overlay remounts and remains editable after returning to screen_1."
)

reset_simulator
if [ "$INCLUDE_ALL_CASES" = "1" ]; then
  echo "Flow runtime UI case mode: all cases"
else
  echo "Flow runtime UI smoke cases: $SMOKE_CASES"
fi
echo "Building flow runtime UI tests once..."
build_for_testing
BUILD_STATUS=$?
if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "Flow runtime UI build failed with status $BUILD_STATUS."
  exit "$BUILD_STATUS"
fi

set +e
STATUS=0
CASE_RESULTS=()
for test_case in "${TEST_CASES[@]}"; do
  IFS='|' read -r test_method slug title description <<< "$test_case"
  if ! case_enabled "$slug"; then
    echo
    echo "Skipping $title ($test_method); not part of the default Flow Runtime UI smoke set."
    continue
  fi

  result_bundle="$RESULT_BUNDLES_DIR/$slug.xcresult"
  video_file="$VIDEOS_DIR/$slug.mp4"
  max_attempts=$((RETRIES + 1))

  echo
  echo "Running $title ($test_method)..."
  case_status=1
  attempt=1
  attempts_used=0
  while [ "$attempt" -le "$max_attempts" ]; do
    attempts_used="$attempt"
    if [ "$attempt" -gt 1 ]; then
      echo "Retrying $title ($test_method), attempt $attempt of $max_attempts..."
    fi

    rm -rf "$result_bundle" "$video_file"
    if [ "$RESET_EACH_CASE" = "1" ] || [ "$attempt" -gt 1 ]; then
      reset_simulator
    fi

    RECORDER_PID=""
    start_recording "$video_file"
    run_xcode_test "$result_bundle" "$test_method"
    case_status=$?
    stop_recording "$RECORDER_PID" "$video_file"

    if [ "$case_status" -eq 0 ]; then
      break
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "$title failed with status $case_status; resetting simulator before retry."
    fi
    attempt=$((attempt + 1))
  done

  CASE_RESULTS+=("$slug|$title|$description|$test_method|$case_status|$attempts_used")
  if [ "$case_status" -ne 0 ] && [ "$STATUS" -eq 0 ]; then
    STATUS="$case_status"
  fi
done
set -e

python3 - "$SCREENSHOTS_DIR" "$RESULT_BUNDLES_DIR"/*.xcresult <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

screenshots_dir = Path(sys.argv[1])
result_bundles = [Path(path) for path in sys.argv[2:]]

screenshots_dir.mkdir(parents=True, exist_ok=True)

def xcresult_json(result_bundle, object_id=None):
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "--legacy",
        "--format",
        "json",
        "--path",
        str(result_bundle),
    ]
    if object_id:
        command.extend(["--id", object_id])
    return json.loads(subprocess.check_output(command))

def value(node):
    if isinstance(node, dict):
        return node.get("_value")
    return None

def walk(node):
    if isinstance(node, dict):
        yield node
        for child in node.values():
            yield from walk(child)
    elif isinstance(node, list):
        for child in node:
            yield from walk(child)

def references(node, target_type):
    for item in walk(node):
        if item.get("_type", {}).get("_name") != "Reference":
            continue
        if value(item.get("targetType", {}).get("name")) != target_type:
            continue
        ref_id = value(item.get("id"))
        if ref_id:
            yield ref_id

def safe_name(raw):
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", raw).strip("-._")
    return name or "screenshot"

for result_bundle in result_bundles:
    if not result_bundle.exists():
        continue

    root = xcresult_json(result_bundle)

    for tests_ref in references(root, "ActionTestPlanRunSummaries"):
        tests = xcresult_json(result_bundle, tests_ref)
        for summary_ref in references(tests, "ActionTestSummary"):
            summary = xcresult_json(result_bundle, summary_ref)
            for attachment in walk(summary):
                if attachment.get("_type", {}).get("_name") != "ActionTestAttachment":
                    continue
                if value(attachment.get("uniformTypeIdentifier")) != "public.png":
                    continue

                payload_id = value(attachment.get("payloadRef", {}).get("id"))
                if not payload_id:
                    continue

                name = value(attachment.get("name")) or value(attachment.get("filename")) or payload_id
                output = screenshots_dir / f"{safe_name(name)}.png"
                index = 2
                while output.exists():
                    output = screenshots_dir / f"{safe_name(name)}-{index}.png"
                    index += 1

                subprocess.check_call([
                    "xcrun",
                    "xcresulttool",
                    "export",
                    "object",
                    "--legacy",
                    "--path",
                    str(result_bundle),
                    "--id",
                    payload_id,
                    "--type",
                    "file",
                    "--output-path",
                    str(output),
                ])
PY

REPORT="$OUTPUT_DIR/index.html"
{
  cat <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Nuxie iOS Flow Runtime UI Report</title>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f7f9; color: #14171f; }
    main { max-width: 1120px; margin: 0 auto; padding: 32px 20px 48px; }
    header { display: flex; justify-content: space-between; gap: 24px; align-items: flex-start; margin-bottom: 28px; }
    h1 { font-size: 24px; line-height: 1.2; margin: 0 0 8px; }
    h2 { font-size: 18px; margin: 0 0 12px; }
    p { margin: 0; color: #596170; }
    .status { padding: 8px 12px; border-radius: 999px; font-weight: 700; font-size: 13px; background: $(if [ "$STATUS" -eq 0 ]; then echo "#def7ec"; else echo "#fde8e8"; fi); color: $(if [ "$STATUS" -eq 0 ]; then echo "#03543f"; else echo "#9b1c1c"; fi); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 18px; }
    .card { background: white; border: 1px solid #dde2ea; border-radius: 10px; padding: 14px; box-shadow: 0 1px 2px rgba(20, 23, 31, 0.05); }
    .card h2 { font-size: 15px; margin: 0 0 12px; }
    .card p { margin-bottom: 10px; }
    .recordings-grid { grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); align-items: start; margin-bottom: 24px; }
    .recording-card { display: flex; flex-direction: column; min-height: 0; }
    .case-status { display: inline-block; padding: 3px 8px; border-radius: 999px; background: #edf0f5; color: #303746; font-size: 12px; font-weight: 700; }
    .summary { margin-bottom: 24px; }
    .summary p { margin-bottom: 12px; }
    .summary ul { margin: 0; padding-left: 20px; color: #303746; }
    .summary li { margin: 6px 0; }
    img { display: block; width: 100%; max-height: min(72vh, 640px); object-fit: contain; border-radius: 8px; border: 1px solid #e6e9ef; background: white; }
    video { display: block; width: 100%; height: clamp(260px, 52vh, 520px); object-fit: contain; border-radius: 8px; border: 1px solid #e6e9ef; background: black; margin-top: 4px; }
    code { background: #edf0f5; border-radius: 5px; padding: 2px 5px; }
    .empty { background: white; border: 1px dashed #b8c0cc; border-radius: 10px; padding: 28px; color: #596170; }
    @media (max-width: 720px) {
      main { padding: 20px 12px 36px; }
      header { flex-direction: column; }
      .recordings-grid { grid-template-columns: 1fr; }
      video { height: min(58vh, 460px); }
    }
  </style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>Nuxie iOS Flow Runtime UI Report</h1>
      <p>Destination: <code>$DESTINATION</code></p>
      <p>Result bundles: <code>$(basename "$RESULT_BUNDLES_DIR")/*.xcresult</code></p>
    </div>
    <div class="status">$(if [ "$STATUS" -eq 0 ]; then echo "Passed"; else echo "Failed ($STATUS)"; fi)</div>
  </header>
  <section class="card summary">
    <h2>How to Review This Run</h2>
    <p>The host app starts fixture scenarios while runtime events stay in hidden accessibility debug text for assertions instead of covering the rendered flow.</p>
    <p>Default smoke cases: <code>$SMOKE_CASES</code>. Set <code>NUXIE_FLOW_RUNTIME_UI_INCLUDE_ALL_CASES=1</code> to run the full forensic suite, or override <code>NUXIE_FLOW_RUNTIME_UI_SMOKE_CASES</code> with a comma-separated slug list.</p>
    <ul>
      <li><strong>System push:</strong> screen_1 starts, screen_2 pushes in as another live Rive surface, then screen_2 becomes current.</li>
      <li><strong>System modal:</strong> UIKit opens screen_2 as a native sheet modal with its own live Rive surface.</li>
      <li><strong>System modal dismissal:</strong> a native sheet swipe dismisses screen_2, reports screen_dismissed, and returns the journey to screen_1.</li>
      <li><strong>Back transition:</strong> screen_2 auto-runs a back action and returns to screen_1 with the push payload.</li>
      <li><strong>Reduce motion:</strong> an authored fade is skipped when reduce motion is forced.</li>
      <li><strong>Text input rebound:</strong> a static UIKit text input overlay remounts and remains editable after returning to screen_1.</li>
    </ul>
  </section>
HTML

  cat <<HTML
  <section>
    <h2>Scenario Recordings</h2>
    <div class="grid recordings-grid">
HTML
  for case_result in "${CASE_RESULTS[@]}"; do
    IFS='|' read -r slug title description test_method case_status attempts <<< "$case_result"
    video_file="$VIDEOS_DIR/$slug.mp4"
    if [ ! -s "$video_file" ]; then
      continue
    fi
    cat <<HTML
      <article class="card recording-card">
        <h2>$title</h2>
        <p>$description</p>
        <p><code>$test_method</code></p>
        <p class="case-status">$(if [ "$case_status" -eq 0 ]; then echo "Passed"; else echo "Failed ($case_status)"; fi)</p>
        <p>Attempts: $attempts</p>
        <video controls src="videos/$(basename "$video_file")"></video>
      </article>
HTML
  done
  cat <<HTML
    </div>
  </section>
HTML

  shopt -s nullglob
  screenshots=("$SCREENSHOTS_DIR"/*.png)
  if [ "${#screenshots[@]}" -eq 0 ]; then
    echo '  <div class="empty">No screenshots were written by the UI tests.</div>'
  else
    echo '  <section class="grid">'
    for screenshot in "${screenshots[@]}"; do
      filename="$(basename "$screenshot")"
      name="${filename%.png}"
      cat <<HTML
    <article class="card">
      <h2>$name</h2>
      <img src="screenshots/$filename" alt="$name screenshot">
    </article>
HTML
    done
    echo '  </section>'
  fi

  cat <<HTML
</main>
</body>
</html>
HTML
} > "$REPORT"

echo "Flow runtime UI report: $REPORT"
exit "$STATUS"
