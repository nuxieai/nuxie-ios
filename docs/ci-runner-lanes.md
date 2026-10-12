# CI runner lanes

The repository pipeline renders `scripts/ci/pipeline.py`. Its default graph
retains the original full readiness commands. `NUXIE_SDK_SPLIT_LANES=1` selects
the platform graph only with `NUXIE_CI_RUNNER_POLICY_VERSION=2` and the
consolidated topology. Invalid activation fails before uploading work.

Each v2 job declares its installed profile and capability before checkout:
Linux uses `linux-16g-v2` with `linux-portable` or `linux-native`; Apple uses
`mac-64g-v2` with `macos-apple`. All substantial jobs use eager concurrency one
in `nuxie/physical/proxmox-heavy` or `nuxie/physical/mac-m2`. The Mac runs one
agent. Repository upload uses Linux portable resources; the LIVE Buildkite
initial upload step must also receive the corresponding selector/profile before
v2 activation. Landing these source files does not change that live bootstrap.

The guarded Bazel frontend loads the actual installed root-owned helper and
policy: `/Library/NuxieBuildkite/hooks/runner-policy.py` and
`/Library/NuxieBuildkite/runner-policy.json` on Mac; Linux uses
`/usr/local/lib/nuxie-buildkite/hooks/runner-policy.py` and
`/etc/nuxie/buildkite-runner-policy.json`. Per-Bazel execution uses its admission,
cache owner lock and ceilings. The whole lane is not wrapped in a nested cache
lock. Profile/BEP files under `output/pipeline/` upload before the owning
post-artifact hook requests installed cleanup; uncertain or active outputs are
preserved. Native product receipts and failure evidence survive cleanup.

Remote caching defaults off, including upload jobs. Separately qualified read
clients require `NUXIE_CI_BAZEL_REMOTE_CACHE_MODE=read`, explicit comma-separated
`NUXIE_CI_BAZEL_CACHE_PROFILES`, eligibility `1`, a `sha256:` toolchain domain,
and all transport inputs: `NUXIE_BAZEL_REMOTE_CACHE_URL`, `_CA_FILE`,
`_TLS_PIN_FILE`, `_CREDENTIAL_FILE`, `_ELIGIBLE`, and `_DOMAIN` (all share the
`NUXIE_BAZEL_REMOTE_CACHE` prefix). The canonical helper validates the protected
single server leaf/pin, origin and private credential file before auth. Missing
qualification keeps the client off. SDK writer requests stay off. Synthetic
wrapper/receipt tests confer no native hermeticity or installed-host qualification.

This work belongs to [UNIV-4312](https://universe.basis.dev/issue/UNIV-4312).
Canonical native readiness remains mandatory before a ready PR; lightweight
fixtures prove routing and receipt behavior only.

The split switch keeps all iOS framework, device, macOS and Swift-consumer
confidence on the Mac. `make test` and the existing released-runtime checks
remain in the lane. Under v2, `sdk.py` invokes the guarded shell frontend and
leaves job/output ceilings to the installed policy; local legacy selection
remains available. Canonical local qualification is `make test`, with the
existing pipeline additionally building the iOS device framework.
