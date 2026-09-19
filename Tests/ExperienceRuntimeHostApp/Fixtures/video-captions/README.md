# Signed caption accessibility fixture

This fixture is generated through Nuxie's normal Rust publisher and development
release signing path. It uses the retained `fixtures/video/captions.mp4` asset,
including its English `mov_text` stream. The SDK must authenticate the descriptor,
verify both content-addressed files, and present its normal video caption overlay.

From the parent repository, generate into a new directory:

```sh
bun tests/e2e/device/tooling/build-video-qualification.mts --captioned --delivery-base-url https://video-captions.sdk-fixtures.nuxie.test/ --output <new-directory>
```

`testSignedVideoCaptionsAppearInPresentationAccessibilityTree` checks the real
presentation's changing static-text caption nodes and their removal after exit.
It does not claim to record VoiceOver speech or measure speaker latency.
