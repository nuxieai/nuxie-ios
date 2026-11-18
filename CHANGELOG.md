# Changelog

## 1.1.0

Updates the embedded runtime to [apple-runtime-v1.2.0](https://github.com/nuxieai/nuxie-runtime/releases/tag/apple-runtime-v1.2.0).

Nuxie runtime 1.2.0

Source: `826d2cc24d4ee7ec0900ab32b00af8ef8e27f17b`

Slim-runtime size comparison against immutable `apple-runtime-v0.4.0` (`e2c8ecff2cd80f47b07909888a5fb3699593348d`; SIZE_REPORT SHA-256 `992a2a852993ab5e550bdd218184fae9dd1d3cdb129e96d0a8d19ecc092198af`):

| Artifact | Metric | Before (bytes) | After (bytes) | Delta (bytes) |
| --- | --- | ---: | ---: | ---: |
| full-apple | compressedBytes | 82078954 | 57069399 | -25009555 |
| full-apple | expandedBytes | 252039298 | 161583848 | -90455450 |
| ios-only | compressedBytes | 49176625 | 34497188 | -14679437 |
| ios-only | expandedBytes | 150926259 | 97761975 | -53164284 |

## 1.0.0

First public 1.0.0 release of the Nuxie Apple SDK.

Uses [Apple runtime 1.0.0](https://github.com/nuxieai/nuxie-runtime/releases/tag/apple-runtime-v1.0.0) with an immutable URL and checksum.
