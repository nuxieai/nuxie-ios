#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "SDK guidance check failed: $1" >&2
  exit 1
}

grep -Fq 'public func reset(keepAnonymousId: Bool = false)' Sources/Nuxie/NuxieSDK.swift \
  || fail 'NuxieSDK.reset default changed'
grep -Fq 'keepAnonymousId = false by default' README.md \
  || fail 'README reset default is stale'
grep -Fq 'NuxieSDK.shared.getCurrentSessionId()' README.md \
  || fail 'README is missing the public session accessor'

for removed_api in startNewSession endSession resetSession 'setSessionId('; do
  if grep -Fq "$removed_api" README.md; then
    fail "README mentions removed manual-session API: $removed_api"
  fi
done

for removed_config in enableFileLogging propertiesSanitizer do-not-track do‑not‑track FactoryKit \
  Container.shared '@Injected(' DI/NuxieContainer.swift; do
  if grep -Fq "$removed_config" README.md CLAUDE.md; then
    fail "top-level guidance mentions removed configuration/infrastructure: $removed_config"
  fi
done

grep -Fq 'test             - Run the full unit + native-runtime + integration + macOS gate' Makefile \
  || fail 'Make help does not describe the full test gate'

echo 'SDK guidance matches the current public surface.'
