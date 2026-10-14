# Runtime environment

The Experience surface owns the read-only global `env` model. Its host updates use the same serial presentation lane as native input. App builders do not register a hinge observer or restore user state when the device folds.

| Value | Contract |
| --- | --- |
| `width`, `height` | Local content surface bounds in logical points, before keyboard avoidance. |
| `safeArea/top`, `right`, `bottom`, `left` | Local safe-area insets. |
| `reduceMotion` | The system motion preference. It does not freeze physical fold observations. |
| `fold/available` | A finite angle and recognized physical state were observed on this surface. |
| `fold/state` | `unavailable`, `unknown`, `closed`, `partially-open`, `fully-open`. |
| `fold/openProgress` | Nuxie normalization: closed 0, fully open 1, partial angle/π clamped to 0…1. |
| `fold/foldProgress` | `1 - openProgress`, from the same observation. |

Unavailable progress uses finite neutral carriers (opening 1, folding 0) and `available = false`. It is not a fully-open observation. Unknown remains distinct from unavailable. Hinge progress is for authored effects; geometry determines layout.

UIKit observation attaches to the SDK's actual rendering view. It requires Xcode 27.1 to compile and uses iOS 27.1 availability guards; earlier deployment targets remain supported with unavailable hinge data. An observation is cleared on window detachment. Repeated callbacks coalesce to one pending write; later writes use the latest values. Changes never emit a second Experience impression, replace the Journey, or reset response values.

Artifacts declare their own environment slots. Older artifacts continue receiving only their existing supported fields. Signed releases that bind fold progress require `environment.fold.v1`; releases binding viewport dimensions require `environment.viewport.v1`. Hardware availability is independent of SDK compatibility: conventional phones can execute a compatible scene with neutral fold effects.

The monorepo's `packages/models/src/env-schema.json` owns authoring types and defaults. These host values are not writable responses or public SDK mutation inputs. Region-aware layout and articulated preview are separate delivery slices.
