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

`captions.mp4` adds two timed-text cues, including Unicode, to the same media.
Its stream order is video (0), audio (1), and `mov_text` (2), as represented by
publishing's signed caption manifest. Regenerate from this directory:

```sh
ffmpeg -i greeting.mp4 -i captions.srt -map 0:v -map 0:a -map 1:0 \
  -c:v copy -c:a copy -c:s mov_text -metadata:s:s:0 language=eng captions.mp4
```

Caption tests check track admission and cue timing from these MP4 bytes, and
runtime projection across forward/backward seeks, cue end boundaries, clearing,
and atomic rejection of an invalid replacement.
