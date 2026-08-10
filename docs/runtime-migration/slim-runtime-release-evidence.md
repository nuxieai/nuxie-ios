# Slim runtime release evidence

Qualification date: 2026-08-09

## Immutable release

- Release: `apple-runtime-v0.5.0`
- Runtime identity: `0.5.0@0a92bc2b6bc91886aee72b673234c9e16a81c910`
- Build-input hash: `064f1a3e2ec8cfad1343beffbe51e5f74f26a94181b3000a88572547d2b3c751`
- Contract fingerprint: `58b390af6f6d30b0f33c00123276fd452019c7c35adb0276328744730f4249d2`
- Published artifact-set SHA-256: `a7a0bd1c1a4375267d990e4fbe10455f84cc3aacce83e53c0a177737512fdaad`
- Published size-report SHA-256: `8130bf5661a1df9608e114d3d5d0d9ebcdcc147fb36799a884ad05206fbfc769`

The exact published `artifact-set.json` and `SIZE_REPORT.json` bytes are
committed under `Runtime/`. `Package.swift` and `Runtime/artifact.json` select
the full Apple archive with SHA-256
`58def1d5e37322c3290e550c65d3535e3bc4b3c5dc03445037b0ac32f97b46cb`.
The independently downloaded iOS-only archive matched SHA-256
`e59f55d461deda4ee55a89ad733ff1508833c475638bf0fb1e413eec6fd7375c`.

## Size comparison

| Evidence | v0.4.0 baseline | v0.5.0 slim | Delta |
| --- | ---: | ---: | ---: |
| Full Apple download | 82,078,954 B | 76,938,454 B | -5,140,500 B |
| Full Apple expanded files | 252,039,298 B | 236,578,711 B | -15,460,587 B |
| iOS-only download | 49,176,625 B | 46,101,008 B | -3,075,617 B |
| iOS-only expanded files | 150,926,259 B | 141,706,141 B | -9,220,118 B |
| Representative Swift iOS link | 31,497,176 B | 29,254,248 B | -2,242,928 B |

The final thin archive members matched the published report exactly:

- iOS device arm64: 47,013,304 B
- iOS simulator arm64: 46,896,368 B
- iOS simulator x86_64: 46,708,920 B
- macOS arm64: 46,791,720 B
- macOS x86_64: 47,993,544 B

The Release generic-device customer framework was arm64-only. Its `Nuxie`
executable was 40,889,704 B and its logical bundle contents were 45,474,473 B.

For a like-for-like application comparison, the production-shaped E2E target
was built from the same SDK source and Xcode configuration against each
immutable runtime release. Both outputs were unsigned and arm64-only:

| Application evidence | v0.4.0 baseline | v0.5.0 slim | Delta |
| --- | ---: | ---: | ---: |
| Embedded linked `Nuxie` executable | 40,291,144 B | 38,128,344 B | -2,162,800 B |
| Logical application files | 40,504,569 B | 38,341,657 B | -2,162,912 B |
| Representative thinned IPA | 14,368,050 B | 13,557,823 B | -810,227 B |

## Clean-cache qualification

The previous artifact directory was moved out of the worktree before
qualification. `make clean` removed generated build state, then
`make fetch-runtime-xcframework-clean` downloaded and qualified v0.5.0 before
creating a new stage. No v0.4 archive was available to the builds or tests.

The fresh stage passed:

- exact package pin, archive checksum, metadata, target matrix, headers,
  module map, exported symbols, layouts, and five thin C/Swift links;
- 690 iOS unit tests, the focused native-runtime subset, 207 integration tests,
  and 657 macOS tests;
- four E2E application tests and one E2E UI test;
- two signed-package runtime reference UI tests;
- Release generic-device linkage and the customer framework privacy/Rust/no-Rive
  audit; and
- the same customer audit for the arm64-only representative application.
