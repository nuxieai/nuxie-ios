#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

prohibited='nuxie[-_]editor|NUXIE_EDITOR|EditorNativeArtifact|GeneratedEditorFixtures|editor-artifact'
prohibited+='|refresh-published-runtime-'"fixtures"
prohibited+='|NuxieE2E'"Tests"
prohibited+='|tools/rive-'"compiler"
prohibited+='|apps/nuxie-'"dashboard"
prohibited+='|github.com/nuxieai/nuxie-'"dev"

if git grep -nE "$prohibited" -- \
  . \
  ':!scripts/check-product-neutrality.sh' \
  ':!fixtures/journeys/parla-sheets/provenance.json' \
  ':!fixtures/runtime/published-fit-content/provenance.json' \
  ':!fixtures/runtime/nested-values/README.md' \
  ':!fixtures/runtime/shared-values/NOTES.md' \
  ':!fixtures/runtime/shared-values/provenance.json' \
  ':!fixtures/runtime/run-values/NOTES.md' \
  ':!fixtures/runtime/run-values/provenance.json' \
  ':!fixtures/runtime/published-input/NOTES.md' \
  ':!fixtures/runtime/published-input/provenance.json' \
  ':!fixtures/runtime/published-two-fields/provenance.json' \
  ':!fixtures/runtime/forms-saves/NOTES.md' \
  ':!fixtures/runtime/earlier-cuts/forms-saves-9ff6ee3e21/NOTES.md' \
  ':!fixtures/runtime/earlier-cuts/forms-saves-9ff6ee3e21/provenance.json' \
  ':!fixtures/runtime/forms-saves/provenance.json' \
  ':!fixtures/runtime/forms-saves/goals/NOTES.md' \
  ':!fixtures/runtime/forms-saves/goals/provenance.json' \
  ':!Tests/ExperienceRuntimeHostApp/Fixtures/animation-event/provenance.json' \
  ':!Tests/ExperienceRuntimeHostApp/Fixtures/external-image/provenance.json' \
  ':!Tests/ExperienceRuntimeHostApp/Fixtures/font-converter/provenance.json' \
  ':!Tests/ExperienceRuntimeHostApp/Fixtures/multi-screen/provenance.json' \
  ':!Tests/ExperienceRuntimeHostApp/Fixtures/scripted-resources/provenance.json' \
  ':!Tests/ExperienceRuntimeHostApp/Fixtures/video-captions/provenance.json' \
  ':!fixtures/journeys/rendered-purchase-absolute/provenance.json' \
  ':!fixtures/journeys/rendered-purchase-navigation/provenance.json' \
  ':!fixtures/journeys/rendered-purchase-scopes/provenance.json' \
  ':!fixtures/journeys/rendered-screen-control-condition/provenance.json' \
  ':!fixtures/journeys/rendered-screen-control-error/provenance.json' \
  ':!fixtures/journeys/rendered-screen-control/provenance.json' \
  ':!fixtures/journeys/rendered-semantic-roles/descriptor.json' \
  ':!fixtures/journeys/rendered-semantic-roles/provenance.json' \
  ':!fixtures/journeys/rendered-semantic-roles/release.json' \
  ':!fixtures/journeys/rendered-semantic-roles/renders/sha256/f5e3ee38eaf045e60417ed73b98a08b705b882571e3f73015473b55193f81539.nux' \
  ':!fixtures/journeys/rendered-semantic-roles/report.json' \
  ':!fixtures/journeys/rendered-semantic-roles/screen.riv' \
  ':!fixtures/journeys/rendered-semantic-screen-control-condition/provenance.json' \
  ':!fixtures/journeys/rendered-semantic-screen-control-error/provenance.json' \
  ':!fixtures/journeys/rendered-semantic-screen-control/provenance.json' \
  ':!fixtures/journeys/rendered-text-input/provenance.json' \
  ':!fixtures/runtime/await-values/provenance.json' \
  ':!fixtures/runtime/choices-set/provenance.json' \
  ':!fixtures/runtime/emit-values/provenance.json' \
  ':!fixtures/runtime/script-tap/provenance.json' \
  ':!fixtures/runtime/system-font-axes/provenance.json'
then
  echo "The public SDK contains Editor-product-specific support. Keep that harness in nuxie-dev." >&2
  exit 1
fi

echo "SDK product-neutrality check passed"
