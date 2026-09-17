# Published video playback fixture

`greeting.nux` is emitted by the Nuxie editor's production publisher from its
neutral Video Frame fixture. `inventory.json` records the matching publisher
inventory. `greeting.mp4` is the shared two-second red/blue H.264 Baseline and
AAC fixture (64 × 32 pixels). Its SHA-256 is
`f0a65563c100506c0f98c138e8be1ae333c9879bb77237fbada60bddcfa78669`.

Regenerate from the parent nuxie-dev repository with:

```sh
pnpm exec tsx tests/e2e/ios/scripts/generate-sdk-video-fixture.mts
```

The SDK test checks two red/blue cycles through AVFoundation and Metal readback,
then checks pause and lifecycle suspension against the runtime's requested state.
This is the native rendering fixture; signed release admission and acquisition
are tested separately by the Journey release and loader suites.
