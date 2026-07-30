#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sdk_root="$(cd "${script_dir}/.." && pwd)"
monorepo_root="$(cd "${sdk_root}/../.." && pwd)"
corpus_relative="tests/e2e/ios/GeneratedEditorFixtures"
source_dir="${monorepo_root}/${corpus_relative}"
destination="${sdk_root}/Tests/ExperienceRuntimeHostApp/Fixtures"
temporary_root=""

cleanup() {
  if [[ -n "${temporary_root}" && -d "${temporary_root}" ]]; then
    rm -rf "${temporary_root}"
  fi
}
trap cleanup EXIT

if [[ ! -f "${source_dir}/native-corpus-manifest.json" ]]; then
  # Older worktrees may predate the generated corpus. This revision is the
  # first checked-in B3 corpus consumed by the S2 Swift cutover.
  corpus_revision="4abef20fc9"
  temporary_root="$(mktemp -d)"
  git -C "${monorepo_root}" archive "${corpus_revision}" "${corpus_relative}" |
    tar -x -C "${temporary_root}"
  source_dir="${temporary_root}/${corpus_relative}"
fi

if [[ ! -f "${source_dir}/native-corpus-manifest.json" ]]; then
  echo "error: package fixture corpus is missing native-corpus-manifest.json" >&2
  exit 1
fi

mkdir -p "${destination}"
rsync -a --delete --exclude='.gitignore' "${source_dir}/" "${destination}/"

echo "Refreshed signed runtime packages from ${source_dir}"
