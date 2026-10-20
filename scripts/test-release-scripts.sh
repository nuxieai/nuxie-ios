#!/usr/bin/env bash

# Offline tests for the release scripts. Each case builds a temporary git
# repository holding the files the release check reads, breaks one thing, and
# requires the check to fail with exactly that one problem. Nothing here
# reaches the network: origin points at a path that does not exist, and curl
# and gh on PATH record any call and fail.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-release-scripts-test.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT

network_log="${temporary}/network.log"
: >"${network_log}"
shims="${temporary}/bin"
mkdir -p "${shims}"
for tool in curl gh; do
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        "echo \"${tool} \$*\" >>\"${network_log}\"" \
        'exit 97' >"${shims}/${tool}"
    chmod +x "${shims}/${tool}"
done

fixture_git() {
    local sdk="$1"
    shift
    git -C "${sdk}" \
        -c user.name="Release Fixture" \
        -c user.email="release-fixture@example.invalid" \
        -c commit.gpgsign=false \
        -c tag.gpgsign=false \
        -c core.hooksPath=/dev/null \
        "$@"
}

# Commit everything and record HEAD as the last fetched origin/main.
commit_and_sync() {
    local sdk="$1"
    local message="$2"
    fixture_git "${sdk}" add -A
    fixture_git "${sdk}" commit -q -m "${message}"
    fixture_git "${sdk}" update-ref refs/remotes/origin/main HEAD
}

write_changelog() {
    local sdk="$1"
    local heading="$2"
    printf '%s\n' \
        '# Changelog' \
        '' \
        "${heading}" \
        '' \
        '- Fixture release notes.' \
        '' \
        '## 1.2.2 (2026-01-01)' \
        '' \
        '- Older notes.' >"${sdk}/CHANGELOG.md"
}

set_sdk_version() {
    local sdk="$1"
    local sdk_version="$2"
    python3 - "${repository_root}/Sources/Nuxie/Util/SDKVersion.swift" \
        "${sdk}/Sources/Nuxie/Util/SDKVersion.swift" "${sdk_version}" <<'PY'
import pathlib
import re
import sys

source, destination, version = sys.argv[1:]
text, count = re.subn(
    r'(static let current = ")[^"]*(")',
    lambda match: match.group(1) + version + match.group(2),
    pathlib.Path(source).read_text(encoding="utf-8"),
)
if count != 1:
    raise SystemExit("SDKVersion.swift no longer has exactly one current version")
pathlib.Path(destination).write_text(text, encoding="utf-8")
PY
}

# A release-ready fixture for 1.2.3 whose origin/main is HEAD.
make_fixture() {
    local sdk="${temporary}/$1/sdk"
    mkdir -p "${sdk}/scripts" "${sdk}/Runtime" "${sdk}/Sources/Nuxie/Util"
    for script in \
        release-check.sh \
        publish-release.sh \
        release-consumer-smoke.sh \
        changelog-section.py \
        check-runtime-package-pin.py \
        json-scalar.py; do
        cp "${repository_root}/scripts/${script}" "${sdk}/scripts/${script}"
    done
    cp "${repository_root}/Package.swift" "${repository_root}/.gitignore" "${sdk}/"
    cp "${repository_root}/Runtime/artifact.json" "${repository_root}/Runtime/artifact-set.json" "${sdk}/Runtime/"
    set_sdk_version "${sdk}" 1.2.3
    write_changelog "${sdk}" '## 1.2.3 (2026-01-02)'
    git init -q -b main "${sdk}"
    git -C "${sdk}" remote add origin "${temporary}/no-network/origin.git"
    commit_and_sync "${sdk}" "fixture"
    printf '%s\n' "${sdk}"
}

run_check() {
    local sdk="$1"
    shift
    env -u NUXIE_RUNTIME_USE_LOCAL PATH="${shims}:${PATH}" \
        bash "${sdk}/scripts/release-check.sh" "$@"
}

expect_pass() {
    local name="$1"
    local sdk="$2"
    shift 2
    local log="${temporary}/${name}.log"
    if ! run_check "${sdk}" "$@" >"${log}" 2>&1; then
        echo "release-check rejected ${name}:" >&2
        cat "${log}" >&2
        exit 1
    fi
    if grep -q '^  FAIL' "${log}"; then
        echo "release-check passed ${name} while reporting a failure:" >&2
        cat "${log}" >&2
        exit 1
    fi
}

# The check must fail, report the expected message, and report no other
# problem, so each case proves exactly one guard.
expect_single_failure() {
    local name="$1"
    local sdk="$2"
    local message="$3"
    shift 3
    local log="${temporary}/${name}.log"
    if run_check "${sdk}" "$@" >"${log}" 2>&1; then
        echo "release-check accepted ${name}:" >&2
        cat "${log}" >&2
        exit 1
    fi
    if ! grep -Fq -- "${message}" "${log}"; then
        echo "release-check did not report '${message}' for ${name}:" >&2
        cat "${log}" >&2
        exit 1
    fi
    if [[ "$(grep -c '^  FAIL' "${log}")" -ne 1 ]]; then
        echo "release-check reported more than the expected problem for ${name}:" >&2
        cat "${log}" >&2
        exit 1
    fi
}

ready="$(make_fixture ready)"

# Happy path: every offline check passes and the network steps are skipped.
expect_pass happy-offline "${ready}" --offline 1.2.3
grep -Fq 'Release check passed for 1.2.3 offline' "${temporary}/happy-offline.log"
grep -Fq 'skip  fetch origin main' "${temporary}/happy-offline.log"
grep -Fq 'skip  download and verify the pinned runtime archive' "${temporary}/happy-offline.log"
grep -Fq 'skip  consumer resolution' "${temporary}/happy-offline.log"

for bad_version in v1.2.3 1.2 1.2.3-beta.1 01.2.3 1.2.3.4; do
    expect_single_failure "bad-version-${bad_version}" "${ready}" \
        "version '${bad_version}' is not X.Y.Z" --offline "${bad_version}"
done
if run_check "${ready}" --offline >/dev/null 2>&1; then
    echo "release-check ran without a version" >&2
    exit 1
fi

# 1.2.2 has CHANGELOG notes, but the source still says 1.2.3.
expect_single_failure sdk-version-mismatch "${ready}" \
    'SDKVersion.current is 1.2.3, expected 1.2.2' --offline 1.2.2

missing_notes="$(make_fixture missing-notes)"
set_sdk_version "${missing_notes}" 1.2.4
commit_and_sync "${missing_notes}" "bump without notes"
expect_single_failure missing-changelog "${missing_notes}" \
    "CHANGELOG.md has no '## 1.2.4' section" --offline 1.2.4

unreleased="$(make_fixture unreleased)"
write_changelog "${unreleased}" '## 1.2.3 (unreleased)'
commit_and_sync "${unreleased}" "notes not dated"
expect_single_failure unreleased-changelog "${unreleased}" \
    "'## 1.2.3' is still marked unreleased" --offline 1.2.3

log="${temporary}/local-runtime.log"
if NUXIE_RUNTIME_USE_LOCAL=1 PATH="${shims}:${PATH}" \
    bash "${ready}/scripts/release-check.sh" --offline 1.2.3 >"${log}" 2>&1; then
    echo "release-check accepted NUXIE_RUNTIME_USE_LOCAL=1" >&2
    cat "${log}" >&2
    exit 1
fi
grep -Fq 'NUXIE_RUNTIME_USE_LOCAL is set' "${log}"
[[ "$(grep -c '^  FAIL' "${log}")" -eq 1 ]]

repinned="$(make_fixture repinned)"
python3 - "${repinned}/Runtime/artifact.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
metadata = json.loads(path.read_text(encoding="utf-8"))
metadata["checksum"] = "0" * 64
path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
PY
commit_and_sync "${repinned}" "pin a different checksum"
expect_single_failure runtime-pin "${repinned}" 'runtime pin: runtime-package-pin:' --offline 1.2.3

printf '%s\n' 'scratch' >"${ready}/untracked.txt"
expect_single_failure dirty-tree "${ready}" \
    'working tree has uncommitted or untracked files' --offline 1.2.3
rm "${ready}/untracked.txt"

ahead="$(make_fixture ahead)"
printf '%s\n' 'unlanded' >"${ahead}/unlanded.txt"
fixture_git "${ahead}" add unlanded.txt
fixture_git "${ahead}" commit -q -m "not on origin/main"
expect_single_failure head-not-origin-main "${ahead}" 'is not origin/main' --offline 1.2.3

moved="$(make_fixture moved)"
tagged_commit="$(git -C "${moved}" rev-parse HEAD)"
fixture_git "${moved}" tag -a 1.2.3 -m "Nuxie iOS SDK 1.2.3"
printf '%s\n' 'landed after the tag' >"${moved}/later.txt"
commit_and_sync "${moved}" "land after tagging"
expect_single_failure tag-elsewhere "${moved}" \
    "local tag 1.2.3 points at ${tagged_commit}, not HEAD" --offline 1.2.3

at_head="$(make_fixture at-head)"
fixture_git "${at_head}" tag -a 1.2.3 -m "Nuxie iOS SDK 1.2.3"
expect_pass tag-at-head "${at_head}" --offline 1.2.3
grep -Fq 'local tag 1.2.3 points at HEAD' "${temporary}/tag-at-head.log"

# Release notes are the section body, up to the next version heading.
notes="$(python3 "${ready}/scripts/changelog-section.py" "${ready}/CHANGELOG.md" 1.2.3)"
[[ "${notes}" == '- Fixture release notes.' ]]
notes_fixture="${temporary}/notes"
mkdir -p "${notes_fixture}"
expect_notes_refused() {
    local name="$1"
    local message="$2"
    local log="${temporary}/notes-${name}.log"
    if python3 "${ready}/scripts/changelog-section.py" "${notes_fixture}/CHANGELOG.md" 1.2.3 >"${log}" 2>&1; then
        echo "changelog-section accepted ${name}" >&2
        exit 1
    fi
    grep -Fq -- "${message}" "${log}"
}
printf '%s\n' '## 1.2.3 (2026-01-02)' '' '- One.' '' '## 1.2.3' '' '- Two.' >"${notes_fixture}/CHANGELOG.md"
expect_notes_refused duplicate "more than one '## 1.2.3' section"
printf '%s\n' '## 1.2.3 (2026-01-02)' '' '' '## 1.2.2' '' '- Older.' >"${notes_fixture}/CHANGELOG.md"
expect_notes_refused empty "'## 1.2.3' section is empty"
printf '%s\n' '## 1.2.3 (2026-02-30)' '' '- One.' >"${notes_fixture}/CHANGELOG.md"
expect_notes_refused bad-date "does not carry a real date"
printf '%s\n' '## 1.2.3 - 2026-01-02' '' '- One.' >"${notes_fixture}/CHANGELOG.md"
expect_notes_refused bad-heading "heading must be '## 1.2.3' or '## 1.2.3 (YYYY-MM-DD)'"

# Publishing refuses a fixture origin before it runs anything that reaches
# GitHub, and a malformed version before anything else.
log="${temporary}/publish-origin.log"
if env -u NUXIE_RUNTIME_USE_LOCAL PATH="${shims}:${PATH}" \
    bash "${ready}/scripts/publish-release.sh" 1.2.3 >"${log}" 2>&1; then
    echo "publish-release accepted a non-public origin" >&2
    exit 1
fi
grep -Fq 'not https://github.com/nuxieai/nuxie-ios' "${log}"
log="${temporary}/publish-version.log"
if PATH="${shims}:${PATH}" bash "${ready}/scripts/publish-release.sh" v1.2.3 >"${log}" 2>&1; then
    echo "publish-release accepted a v-prefixed version" >&2
    exit 1
fi
grep -Fq "version 'v1.2.3' is not X.Y.Z" "${log}"
if [[ -n "$(git -C "${ready}" tag --list)" ]]; then
    echo "a release script created a tag in the fixture" >&2
    exit 1
fi

set +e
bash "${ready}/scripts/release-consumer-smoke.sh" --url "file://${temporary}/none.git" --version 1.2 --exact >/dev/null 2>&1
smoke_status=$?
set -e
if [[ "${smoke_status}" -ne 64 ]]; then
    echo "release-consumer-smoke accepted version 1.2 (exit ${smoke_status})" >&2
    exit 1
fi

if [[ -s "${network_log}" ]]; then
    echo "offline release tests reached the network:" >&2
    cat "${network_log}" >&2
    exit 1
fi

echo "Release scripts fail closed for version format, SDK version, notes, local runtime, runtime pin, tree, origin/main, and tags"
