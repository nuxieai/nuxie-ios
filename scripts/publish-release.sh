#!/usr/bin/env bash

# Publish the GitHub release for an X.Y.Z tag that is already on origin at the
# tip of main. The notes are the CHANGELOG.md section for X.Y.Z.
#
# It never creates, moves, or deletes a tag, and never replaces or deletes a
# release: the release is created as a draft against the existing tag, read
# back, and only then published. A consumer resolution of the public URL runs
# last. See RELEASING.md.

set -euo pipefail

repository="nuxieai/nuxie-ios"
public_url="https://github.com/${repository}"

if [[ $# -ne 1 ]]; then
    echo "usage: $0 X.Y.Z" >&2
    exit 64
fi
version="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

die() {
    echo "publish-release: $1" >&2
    exit 1
}

if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    die "version '${version}' is not X.Y.Z (plain semver: no 'v' prefix, no suffix)"
fi

# The tag checked on origin must be the tag GitHub publishes.
origin_url="$(git -C "${repo_root}" remote get-url origin)"
if [[ ! "${origin_url}" =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)nuxieai/nuxie-ios(\.git)?/?$ ]]; then
    die "origin is ${origin_url}, not ${public_url}"
fi

"${script_dir}/release-check.sh" "${version}"

head="$(git -C "${repo_root}" rev-parse --verify HEAD)"
origin_main="$(git -C "${repo_root}" rev-parse --verify "refs/remotes/origin/main^{commit}")"
if [[ "${head}" != "${origin_main}" ]]; then
    die "HEAD ${head} is not origin/main ${origin_main}"
fi
local_tag="$(git -C "${repo_root}" rev-parse -q --verify "refs/tags/${version}^{commit}" || true)"
if [[ "${local_tag}" != "${head}" ]]; then
    die "local tag ${version} must exist and point at HEAD ${head}; create and push it first (RELEASING.md)"
fi

remote_tag_commit() {
    local records peeled plain
    records="$(git -C "${repo_root}" ls-remote origin "refs/tags/${version}" "refs/tags/${version}^{}")" || return 1
    peeled="$(awk -v ref="refs/tags/${version}^{}" '$2 == ref { print $1 }' <<<"${records}")"
    plain="$(awk -v ref="refs/tags/${version}" '$2 == ref { print $1 }' <<<"${records}")"
    printf '%s\n' "${peeled:-${plain}}"
}
remote_tag="$(remote_tag_commit)" || die "could not list tags on origin"
if [[ "${remote_tag}" != "${head}" ]]; then
    die "tag ${version} on origin is '${remote_tag:-absent}', expected HEAD ${head}; push the tag first (RELEASING.md)"
fi

# Drafts are included: a draft that already uses the tag is also a release.
existing="$(gh api --paginate "repos/${repository}/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"${version}\") | .html_url")"
if [[ -n "${existing}" ]]; then
    die "a release for ${version} already exists (${existing}); releases are never replaced"
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-release-publish.XXXXXX")"
draft_requested=0
published=0
finish() {
    local status=$?
    rm -rf "${temporary}"
    if [[ "${status}" -ne 0 && "${draft_requested}" -eq 1 && "${published}" -eq 0 ]]; then
        cat >&2 <<EOF
publish-release: stopped after asking GitHub for the draft release of ${version}.
  Nothing was deleted. Look for it: gh release view ${version} --repo ${repository}
  When it reads correctly, publish: gh release edit ${version} --repo ${repository} --draft=false
  Then check a consumer:            scripts/release-consumer-smoke.sh --url ${public_url} --version ${version} --from --revision ${head}
EOF
    elif [[ "${status}" -ne 0 && "${published}" -eq 1 ]]; then
        echo "publish-release: ${version} is published; only the post-publish check failed." >&2
    fi
}
trap finish EXIT

notes="${temporary}/notes.md"
python3 "${script_dir}/changelog-section.py" "${repo_root}/CHANGELOG.md" "${version}" >"${notes}"
title="Nuxie iOS SDK ${version}"

# From here a draft may exist even if a command fails, so a failure reports it.
draft_requested=1
gh release create "${version}" \
    --repo "${repository}" \
    --draft \
    --verify-tag \
    --title "${title}" \
    --notes-file "${notes}"

check_release() {
    local expect_draft="$1"
    gh release view "${version}" --repo "${repository}" \
        --json tagName,isDraft,name,body,publishedAt >"${temporary}/release.json"
    python3 - "${temporary}/release.json" "${notes}" "${version}" "${title}" "${expect_draft}" <<'PY'
import json
import pathlib
import sys

release_path, notes_path, version, title, expect_draft = sys.argv[1:]
release = json.loads(pathlib.Path(release_path).read_text(encoding="utf-8"))


def normalized(text):
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").strip().split("\n"))


problems = []
if release.get("tagName") != version:
    problems.append(f"tag is {release.get('tagName')!r}")
if release.get("isDraft") is not (expect_draft == "draft"):
    problems.append(f"isDraft is {release.get('isDraft')!r}")
if release.get("name") != title:
    problems.append(f"title is {release.get('name')!r}")
if normalized(release.get("body") or "") != normalized(pathlib.Path(notes_path).read_text(encoding="utf-8")):
    problems.append("notes differ from the CHANGELOG section")
if expect_draft == "published" and not release.get("publishedAt"):
    problems.append("publishedAt is empty")
if problems:
    raise SystemExit(f"publish-release: {expect_draft} release {version}: " + "; ".join(problems))
PY
}

check_release draft
remote_tag="$(remote_tag_commit)" || die "could not list tags on origin"
if [[ "${remote_tag}" != "${head}" ]]; then
    die "tag ${version} on origin is '${remote_tag:-absent}' after creating the draft, expected ${head}"
fi

gh release edit "${version}" --repo "${repository}" --draft=false >/dev/null
published=1
check_release published
echo "Published ${public_url}/releases/tag/${version}"

"${script_dir}/release-consumer-smoke.sh" \
    --url "${public_url}" \
    --version "${version}" \
    --from \
    --revision "${head}"
