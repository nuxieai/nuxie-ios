# `.nux` trust phases on Apple platforms

The SDK implements the version 1 acquisition contract owned by
`nux-container` in `nuxie-runtime`. The implementations do not share source
code. The copied conformance fixture at
`fixtures/nux/acquisition-contract-v1.json` pins the same limits, field allowlist,
and stable error vocabulary.

## Phase 1: untrusted acquisition

`NuxPackageReader` checks the bounded container envelope and returns
`NuxPackageAcquisitionMetadataV1`. The type contains only expected delivery
identity and content-addressed external image/font descriptors. The package
store may use those descriptors to download, size-check, hash, and cache bytes.

Journey, product, script, screen, text-input, and side-effect-bearing fields are
not represented by the acquisition type. They cannot hydrate SDK state or start
runtime execution.

## Phase 2: authenticated package

`SwiftExperiencePackageAuthenticator` reparses the exact package bytes and
performs the trust decision entirely in Swift. It rejects duplicate and unknown
manifest/signature fields, binds the signed inventory to every raw member and
hash, verifies Ed25519 with CryptoKit over the exact stored manifest bytes,
checks the signed delivery identity, and re-hashes embedded and prepared
external assets. Only then does it decode `JourneyDocument` and return an
owned `AuthenticatedRuntimePayload` containing the scene and generic assets.

The runtime receives only those authenticated bytes; it has no package,
experience, build, or authorization-key concept. The temporary
`ExperiencePackageAuthenticator+Legacy.swift` path remains solely for the old
presentation host until its planned cutover and is excluded from product
loading.

Product lookup, screen/text-input construction, and runtime mounting require
the Swift-authenticated payload (wrapped temporarily as
`LoadedExperiencePackage` for existing presentation code). Failed acquisition
or authentication therefore cannot cross the execution boundary.
