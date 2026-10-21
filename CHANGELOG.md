# Changelog

## 0.1.1

Updates the embedded runtime to [apple-runtime-v0.10.17](https://github.com/nuxieai/nuxie-runtime/releases/download/apple-runtime-v0.10.17).

Nuxie runtime 0.10.17

Source: `c36d8c44157903b8c6b12c030bb4acd080e2ae9e`

Slim-runtime size comparison against immutable `apple-runtime-v0.4.0` (`e2c8ecff2cd80f47b07909888a5fb3699593348d`; SIZE_REPORT SHA-256 `992a2a852993ab5e550bdd218184fae9dd1d3cdb129e96d0a8d19ecc092198af`):

| Artifact | Metric | Before (bytes) | After (bytes) | Delta (bytes) |
| --- | --- | ---: | ---: | ---: |
| full-apple | compressedBytes | 82078954 | 43244492 | -38834462 |
| full-apple | expandedBytes | 252039298 | 129172436 | -122866862 |
| ios-only | compressedBytes | 49176625 | 26303696 | -22872929 |
| ios-only | expandedBytes | 150926259 | 78404242 | -72522017 |
