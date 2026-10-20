#!/usr/bin/env bash

# Check that the current checkout can be tagged as SDK version X.Y.Z.
#
# Read-only: it never creates, moves, or pushes a tag and never touches GitHub
# releases. It writes only temporary directories, the remote-tracking ref
# origin/main, and the ignored SwiftPM .build directory. Content and git checks
# all run and report together; the network checks run only when those pass.
#
# --offline skips every step that needs the network: fetching origin, reading
# the tag on origin, downloading the runtime, and the consumer resolution. An
# offline pass is not enough to tag. See RELEASING.md.

set -euo pipefail

usage() {
    echo "usage: $0 [--offline] X.Y.Z" >&2
    exit 64
}

offline=0
version=""
version_given=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) offline=1; shift ;;
        -*) usage ;;
        *)
            [[ "${version_given}" -eq 0 ]] || usage
            version="$1"
            version_given=1
            shift
            ;;
    esac
done
if [[ -z "${version}" ]]; then
    usage
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
artifact_metadata="${repo_root}/Runtime/artifact.json"

failures=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }
skip() { echo "  skip  $1"; }

echo "Release check for ${version}$([[ "${offline}" -eq 1 ]] && echo ' (offline)')"

if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "version '${version}' is not X.Y.Z (plain semver: no 'v' prefix, no suffix, no leading zeros)"
    echo "Release check failed for ${version}: 1 problem"
    exit 1
fi
pass "version ${version} is X.Y.Z"

# SDKVersion.current is sent as $lib_version and in the User-Agent, and is
# compared with a signed Journey release's minimumSdkVersion.
sdk_version_file="${repo_root}/Sources/Nuxie/Util/SDKVersion.swift"
if sdk_version="$(python3 - "${sdk_version_file}" 2>&1 <<'PY'
import pathlib
import re
import sys

try:
    text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"cannot read {sys.argv[1]}: {error}")
values = re.findall(r'^\s*static let current = "([^"]*)"\s*$', text, re.MULTILINE)
if len(values) != 1:
    raise SystemExit("SDKVersion.swift must declare exactly one 'static let current = \"X.Y.Z\"'")
print(values[0])
PY
)"; then
    if [[ "${sdk_version}" == "${version}" ]]; then
        pass "SDKVersion.current is ${version}"
    else
        fail "SDKVersion.current is ${sdk_version}, expected ${version}"
    fi
else
    fail "${sdk_version}"
fi

if changelog_output="$(python3 "${script_dir}/changelog-section.py" "${repo_root}/CHANGELOG.md" "${version}" 2>&1)"; then
    pass "CHANGELOG.md has release notes under '## ${version}'"
else
    fail "${changelog_output#changelog-section: }"
fi

if [[ -n "${NUXIE_RUNTIME_USE_LOCAL+set}" ]]; then
    fail "NUXIE_RUNTIME_USE_LOCAL is set; a release resolves only the pinned runtime release"
else
    pass "NUXIE_RUNTIME_USE_LOCAL is unset"
fi

if pin_output="$(python3 "${script_dir}/check-runtime-package-pin.py" "${artifact_metadata}" 2>&1)"; then
    pass "${pin_output}"
else
    fail "runtime pin: ${pin_output}"
fi

head="$(git -C "${repo_root}" rev-parse --verify HEAD)"

dirty="$(git -C "${repo_root}" status --porcelain --untracked-files=all)"
if [[ -z "${dirty}" ]]; then
    pass "working tree is clean"
else
    fail "working tree has uncommitted or untracked files:"
    printf '%s\n' "${dirty}" | head -n 20 | sed 's/^/          /'
fi

if [[ "${offline}" -eq 1 ]]; then
    skip "fetch origin main (offline: comparing with the last fetched origin/main)"
elif ! git -C "${repo_root}" fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main"; then
    fail "could not fetch main from origin"
fi
if origin_main="$(git -C "${repo_root}" rev-parse -q --verify "refs/remotes/origin/main^{commit}")"; then
    if [[ "${head}" == "${origin_main}" ]]; then
        pass "HEAD ${head} is origin/main"
    else
        fail "HEAD ${head} is not origin/main ${origin_main}; release from an up-to-date main"
    fi
else
    fail "origin/main is unknown; fetch origin first"
fi

if git -C "${repo_root}" show-ref --verify --quiet "refs/tags/${version}"; then
    local_tag="$(git -C "${repo_root}" rev-parse -q --verify "refs/tags/${version}^{commit}" || true)"
    if [[ "${local_tag}" == "${head}" ]]; then
        pass "local tag ${version} points at HEAD"
    else
        fail "local tag ${version} points at ${local_tag:-a non-commit}, not HEAD ${head}; tags are never moved, release the next version"
    fi
else
    pass "local tag ${version} does not exist yet"
fi

if [[ "${offline}" -eq 1 ]]; then
    skip "tag ${version} on origin (offline)"
elif remote_records="$(git -C "${repo_root}" ls-remote origin "refs/tags/${version}" "refs/tags/${version}^{}")"; then
    remote_tag="$(awk -v ref="refs/tags/${version}^{}" '$2 == ref { print $1 }' <<<"${remote_records}")"
    if [[ -z "${remote_tag}" ]]; then
        remote_tag="$(awk -v ref="refs/tags/${version}" '$2 == ref { print $1 }' <<<"${remote_records}")"
    fi
    if [[ -z "${remote_tag}" ]]; then
        pass "tag ${version} does not exist on origin yet"
    elif [[ "${remote_tag}" == "${head}" ]]; then
        pass "tag ${version} on origin points at HEAD"
    else
        fail "tag ${version} on origin points at ${remote_tag}, not HEAD ${head}; tags are never moved, release the next version"
    fi
else
    fail "could not list tags on origin"
fi

if [[ "${failures}" -gt 0 ]]; then
    echo "Release check failed for ${version}: ${failures} problem$([[ "${failures}" -eq 1 ]] || echo s)"
    exit 1
fi

if [[ "${offline}" -eq 1 ]]; then
    skip "download and verify the pinned runtime archive (offline)"
    skip "consumer resolution of a temporary ${version} tag (offline)"
    echo "Release check passed for ${version} offline; run it without --offline before tagging"
    exit 0
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-release-check.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT

# The archive goes into its own empty directory; nothing inside it runs.
runtime_url="$(python3 "${script_dir}/json-scalar.py" "${artifact_metadata}" url string)"
runtime_checksum="$(python3 "${script_dir}/json-scalar.py" "${artifact_metadata}" checksum string)"
mkdir -p "${temporary}/runtime/unpacked"
runtime_archive="${temporary}/runtime/NuxieRuntime.xcframework.zip"
if ! curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    --output "${runtime_archive}" "${runtime_url}"; then
    fail "could not download ${runtime_url}"
    echo "Release check failed for ${version}: 1 problem"
    exit 1
fi
actual_checksum="$(shasum -a 256 "${runtime_archive}" | awk '{ print $1 }')"
if [[ "${actual_checksum}" != "${runtime_checksum}" ]]; then
    fail "runtime archive SHA-256 is ${actual_checksum}, pinned ${runtime_checksum}"
    echo "Release check failed for ${version}: 1 problem"
    exit 1
fi
pass "pinned runtime archive downloads with SHA-256 ${runtime_checksum}"
ditto -x -k "${runtime_archive}" "${temporary}/runtime/unpacked"
if verify_output="$("${script_dir}/verify-runtime-artifact.sh" \
    --metadata "${artifact_metadata}" \
    --archive "${runtime_archive}" \
    --xcframework "${temporary}/runtime/unpacked/NuxieRuntime.xcframework" 2>&1)"; then
    pass "$(tail -n 1 <<<"${verify_output}")"
else
    fail "runtime artifact verification failed:"
    tail -n 20 <<<"${verify_output}" | sed 's/^/          /'
    echo "Release check failed for ${version}: 1 problem"
    exit 1
fi

# A bare copy of HEAD with a temporary tag stands in for the published tag.
# The tag exists only inside the temporary directory.
consumer_origin="${temporary}/nuxie-ios.git"
git init --quiet --bare "${consumer_origin}"
git -C "${consumer_origin}" symbolic-ref HEAD refs/heads/main
git -C "${repo_root}" push --quiet --no-verify "${consumer_origin}" "${head}:refs/heads/main"
git -C "${consumer_origin}" tag "${version}" "${head}"
if smoke_output="$("${script_dir}/release-consumer-smoke.sh" \
    --url "file://${consumer_origin}" \
    --version "${version}" \
    --exact \
    --revision "${head}" 2>&1)"; then
    pass "${smoke_output}"
else
    fail "consumer resolution failed:"
    printf '%s\n' "${smoke_output}" | sed 's/^/          /'
    echo "Release check failed for ${version}: 1 problem"
    exit 1
fi

echo "Release check passed for ${version} at ${head}"
