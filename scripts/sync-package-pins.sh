#!/usr/bin/env bash
# Keep xcodebuild's package resolution pinned to the committed Package.resolved.
#
# The generated NuxieSDK.xcodeproj resolves Swift packages into its own
# workspace Package.resolved (NuxieSDK.xcodeproj/project.xcworkspace/
# xcshareddata/swiftpm/). Without seeding that file, branch dependencies such
# as nuxieai/rive-ios resolve from whatever revision a cached package mirror
# happens to hold — on CI a restored .xcode-spm cache silently pins the fork
# at a stale main. Seeding the committed root Package.resolved makes
# xcodebuild check out exactly the pinned revisions, fetching them when the
# mirror predates them.
#
# Bump the rive-ios pin with `swift package update rive-ios` (updates the
# root Package.resolved), then regenerate via `make generate`.

set -euo pipefail

cd "$(dirname "$0")/.."

ROOT_RESOLVED="Package.resolved"
WORKSPACE_SWIFTPM_DIR="NuxieSDK.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
WORKSPACE_RESOLVED="$WORKSPACE_SWIFTPM_DIR/Package.resolved"

pin_revision() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
for pin in data["pins"]:
    if pin["identity"] == "rive-ios":
        print(pin["state"]["revision"])
        raise SystemExit(0)
raise SystemExit(f"error: no rive-ios pin in {path}")
PY
}

case "${1:-}" in
  seed)
    if [ ! -d "NuxieSDK.xcodeproj" ]; then
      echo "error: NuxieSDK.xcodeproj not found; run 'make generate' first" >&2
      exit 1
    fi
    mkdir -p "$WORKSPACE_SWIFTPM_DIR"
    cp "$ROOT_RESOLVED" "$WORKSPACE_RESOLVED"
    ;;
  verify)
    expected="$(pin_revision "$ROOT_RESOLVED")"
    actual="$(pin_revision "$WORKSPACE_RESOLVED")"
    if [ "$expected" != "$actual" ]; then
      echo "error: rive-ios resolved to $actual but Package.resolved pins $expected" >&2
      exit 1
    fi
    echo "rive-ios resolution pinned at $expected"
    ;;
  *)
    echo "usage: $0 seed|verify" >&2
    exit 2
    ;;
esac
