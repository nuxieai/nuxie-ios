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

`multilingual.mp4` retains English at stream 2 and adds French at stream 3.
The playback test requests `fr-CA`, verifies French cues through native playback,
and exercises two video loops, resource retirement, pause, and lifecycle resume.
Regenerate from this directory:

```sh
ffmpeg -i greeting.mp4 -i captions.srt -i captions-fr.srt \
  -map 0:v -map 0:a -map 1:0 -map 2:0 -c:v copy -c:a copy -c:s mov_text \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=fra multilingual.mp4
```

`captions-720p.mp4` is a square-pixel 1280×720 rendition for SDK delivery measurements.
It preserves the same timing, audio, and caption stream. Regenerate with:

```sh
ffmpeg -i captions.mp4 -map 0 -vf scale=1280:720:flags=neighbor,setsar=1 \
  -c:v libx264 -profile:v baseline -level:v 3.1 -pix_fmt yuv420p \
  -c:a copy -c:s copy captions-720p.mp4
```

The measurement test runs one and two simultaneous players. Its JSON attachment
reports actual delivered decoded frames, bridge tick time, and Metal allocation.
It includes forced scene readback and targets a 60 Hz update cadence; these are qualification
measurements, not a claim about unrestricted decoder throughput or A/V skew.

`captions-anamorphic.mp4` has 64×32 coded pixels and 2:1 sample aspect ratio.
Android's player reports 128×32 display pixels; the decoder-budget regression
compares the actual RGBA frame dimensions with the media probe's work estimate.
Regenerate with:

```sh
ffmpeg -i captions.mp4 -map 0 -vf setsar=2 -c:v libx264 -profile:v baseline \
  -pix_fmt yuv420p -c:a copy -c:s copy captions-anamorphic.mp4
```
