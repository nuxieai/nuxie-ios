#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT

"${repository_root}/scripts/check-product-neutrality.sh" >/dev/null

mkdir -p "${temporary}/sdk/scripts"
cp "${repository_root}/scripts/check-product-neutrality.sh" \
  "${temporary}/sdk/scripts/check-product-neutrality.sh"

git -C "${temporary}/sdk" init -q
printf '%s\n' "public SDK fixture" >"${temporary}/sdk/README.md"
git -C "${temporary}/sdk" add README.md scripts/check-product-neutrality.sh
"${temporary}/sdk/scripts/check-product-neutrality.sh" >/dev/null

printf '%s%s\n' "final class EditorNative" "ArtifactFixture {}" \
  >"${temporary}/sdk/ProductSpecific.swift"
git -C "${temporary}/sdk" add ProductSpecific.swift

failure_log="${temporary}/failure.log"
if "${temporary}/sdk/scripts/check-product-neutrality.sh" \
  >"${failure_log}" 2>&1; then
  echo "Product-neutrality guard accepted Editor-specific SDK support" >&2
  exit 1
fi

grep -F "ProductSpecific.swift" "${failure_log}" >/dev/null
grep -F "Keep that harness in nuxie-dev" "${failure_log}" >/dev/null

git -C "${temporary}/sdk" rm -q -f ProductSpecific.swift
printf '%s%s\n' "refresh-published-runtime-" "fixtures" \
  >"${temporary}/sdk/InternalFixtureTooling.txt"
git -C "${temporary}/sdk" add InternalFixtureTooling.txt

if "${temporary}/sdk/scripts/check-product-neutrality.sh" \
  >"${failure_log}" 2>&1; then
  echo "Product-neutrality guard accepted internal fixture tooling" >&2
  exit 1
fi

grep -F "InternalFixtureTooling.txt" "${failure_log}" >/dev/null
grep -F "Keep that harness in nuxie-dev" "${failure_log}" >/dev/null

echo "SDK product-neutrality guard fails closed"
