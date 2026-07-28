#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

prohibited='nuxie[-_]editor|NUXIE_EDITOR|EditorNativeArtifact|GeneratedEditorFixtures|editor-artifact'

if git grep -nE "$prohibited" -- \
  . \
  ':!scripts/check-product-neutrality.sh'
then
  echo "The public SDK contains Editor-product-specific support. Keep that harness in nuxie-dev." >&2
  exit 1
fi

echo "SDK product-neutrality check passed"
