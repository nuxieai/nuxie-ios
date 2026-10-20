# Releasing the Nuxie iOS SDK

A release is an annotated git tag on `main` plus a GitHub release whose notes
are that version's section of [CHANGELOG.md](CHANGELOG.md). Swift Package
Manager and Xcode read versions from tags only; the GitHub release is for
people. The process follows the one nuxie-runtime uses for its Apple binary:
check a clean, up-to-date `main`, tag it, then publish a draft that is read
back before it goes public.

Two rules hold throughout:

- **The runtime binary must already be a published nuxie-runtime release.**
  `Package.swift` and `Runtime/artifact.json` pin one
  `NuxieRuntime.xcframework.zip` from a
  [nuxie-runtime release](https://github.com/nuxieai/nuxie-runtime/releases)
  (for example `apple-runtime-v0.10.16`) by URL and checksum, so a tagged SDK
  commit selects exactly one runtime build. Publish the runtime first, land the
  pin on `main`, then release the SDK. Never release with
  `NUXIE_RUNTIME_USE_LOCAL` set or with an unpublished runtime.
- **Tags are never moved or deleted, and published releases are never
  replaced.** Apps and SwiftPM caches remember which commit a version named.
  If a tag or release is wrong, release the next patch version.

## Version policy

- Tags are plain semantic versions `X.Y.Z` with no `v` prefix, for example
  `0.1.0`. SwiftPM and Xcode list these tags as package versions.
- Before 1.0, a new minor version (`0.1.x` to `0.2.0`) may break source
  compatibility or behaviour; a patch version (`0.1.0` to `0.1.1`) does not.
  Integration docs therefore recommend Xcode's "Up to Next Minor Version" rule,
  or `.upToNextMinor(from: "X.Y.Z")` in `Package.swift`.
- `SDKVersion.current` in `Sources/Nuxie/Util/SDKVersion.swift` equals the
  tag. The SDK sends it as `$lib_version` and in its User-Agent, and compares
  it with the `minimumSdkVersion` a signed Journey release requires.

## 1. Open the release pull request

On a branch from the current `main`:

1. Set `SDKVersion.current` to `X.Y.Z`.
2. Add a `## X.Y.Z (YYYY-MM-DD)` section at the top of `CHANGELOG.md`, dated
   the day you will tag, describing what changed for integrators since the
   previous tag (`git log --oneline <previous-tag>..origin/main`). Name the
   runtime release the package pins. For 0.1.0 the section already exists as
   `## 0.1.0 (unreleased)`; replace `(unreleased)` with the date.
3. For the first release only, change README.md "Installation" from a branch
   or commit rule to "Up to Next Minor Version" from `0.1.0`.
4. Run `make test` and list the result in the pull request body.

Land it on `main`. Nothing else should land between this pull request and the
tag.

## 2. Check `main`

From a clean checkout at the tip of `main`:

```sh
git fetch origin
git switch --detach origin/main
make release-check VERSION=X.Y.Z
```

`release-check` is read-only. It writes only temporary directories, the
`origin/main` remote-tracking ref, and the ignored SwiftPM `.build` directory.
It fails unless:

- `X.Y.Z` is a plain semantic version;
- `SDKVersion.current` is `X.Y.Z`;
- `CHANGELOG.md` has a non-empty `## X.Y.Z` section that is no longer marked
  unreleased;
- `NUXIE_RUNTIME_USE_LOCAL` is unset and `make check-runtime-package-pin`
  passes;
- the working tree is clean, including untracked files;
- `HEAD` is `origin/main` after a fetch;
- the tag `X.Y.Z` is absent, or already points at `HEAD`, both locally and on
  origin;
- the pinned runtime archive downloads, its SHA-256 equals the pinned checksum,
  and `scripts/verify-runtime-artifact.sh` accepts it; and
- a fresh temporary SwiftPM package resolves the `Nuxie` product at
  `exact: "X.Y.Z"` from a temporary copy of the repository tagged `X.Y.Z` at
  `HEAD`. This is resolution only: it proves SwiftPM sees the version and
  fetches the runtime binary, without building the SDK for macOS.

`make release-check VERSION=X.Y.Z OFFLINE=1` runs only the steps that need no
network. An offline pass is not enough to tag.

## 3. Tag

```sh
git tag -a X.Y.Z -m "Nuxie iOS SDK X.Y.Z"
git push origin refs/tags/X.Y.Z
```

Push only this tag, by name. Never use `git push --tags` or force. Once the tag
is on GitHub, SwiftPM can resolve the version, so publish right away.

## 4. Publish the GitHub release

```sh
scripts/publish-release.sh X.Y.Z
```

This needs `gh` signed in with write access to `nuxieai/nuxie-ios`. The script:

1. requires `origin` to be `github.com/nuxieai/nuxie-ios` and reruns
   `release-check` in full;
2. requires the tag on origin and locally to point at `HEAD`, which is
   `origin/main`;
3. refuses if any release, draft or published, already uses the tag;
4. creates a draft release for the existing tag (`gh release create --draft
   --verify-tag`) with the CHANGELOG section as its notes;
5. reads the draft back and checks its tag, title, and notes, and that the tag
   on origin has not changed;
6. publishes it; and
7. resolves `https://github.com/nuxieai/nuxie-ios` with `from: "X.Y.Z"` in a
   fresh temporary package and requires version `X.Y.Z` at the tagged commit.

If `main` moves between the tag and this step, the script refuses. The tag
stays, since SwiftPM can already resolve it. From a checkout of the tag, write
its release by hand with the same notes:

```sh
python3 scripts/changelog-section.py CHANGELOG.md X.Y.Z > /tmp/notes.md
gh release create X.Y.Z --repo nuxieai/nuxie-ios --verify-tag \
  --title "Nuxie iOS SDK X.Y.Z" --notes-file /tmp/notes.md
```

If the script stops after creating the draft, it says so and deletes nothing.
Read the draft with `gh release view X.Y.Z --repo nuxieai/nuxie-ios`, publish
it with `gh release edit X.Y.Z --repo nuxieai/nuxie-ios --draft=false` once it
is right, then run the consumer check it prints.

## 5. Check as an app would

The publish script already resolves the public package. Also add it to a new
iOS app once: in Xcode, File > Add Package Dependencies, enter
`https://github.com/nuxieai/nuxie-ios`, choose "Up to Next Minor Version" from
`X.Y.Z`, add the `Nuxie` product, and build for an iOS simulator.

## 6. After the release, in nuxie-dev

- Move the parent repository's `sdks/nuxie-ios` submodule pointer to the
  tagged commit.
- Switch the iOS install guidance from "Branch: main" to "Up to Next Minor
  Version" from `X.Y.Z` (`.upToNextMinor(from: "X.Y.Z")`): the iOS pages in
  `apps/nuxie-docs` and the Swift recipe in
  `packages/core/src/sdk/sdk-setup-recipes.ts` that the dashboard shows. After
  the first release these only need the new version number.

## Changing the release scripts

The scripts are `scripts/release-check.sh`, `scripts/publish-release.sh`,
`scripts/release-consumer-smoke.sh`, and `scripts/changelog-section.py`. Run
`make test-release-scripts` after changing them; it exercises the checks
offline against temporary git repositories.
