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

`NativeExperiencePackageAuthenticator` passes the exact package bytes,
delivery-pointer identity, candidate keys, and acquired assets to the runtime.
Rust reparses the package, validates member inventory and hashes, verifies the
manifest signature and identity binding, and imports the scene. Only after that
succeeds does Swift create `LoadedExperiencePackage` by decoding the complete
manifest and journey from those same bytes.

Product lookup, journey hydration, screen/text-input construction, and runtime
mounting require `LoadedExperiencePackage`. A failed acquisition or native
authentication therefore cannot cross the execution boundary.
