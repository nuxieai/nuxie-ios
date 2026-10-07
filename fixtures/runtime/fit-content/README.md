# Root-height binding proof fixtures

The two `root-height-*` files are byte-for-byte copies from the runtime thread's
2026-10-07 fit-content proof. Source and retained upstream/port probe logs:
`/Users/levi/dev/nuxie-codex/runtime-landing-notes/evidence/fit-content`.
They declare proof-only global `Presentation`, number `heightMode`; values 0
(Fixed) and 2 (Hug) drive root style property 656. These are not reserved
production model names. The no-binding control still contains the global.

Independent oracle: padding 16 + fixed child 120 + padding 16 = 152, at widths
300 and 500. Fixed restores the supplied 600/700. Removing the root binding
keeps the supplied fixed size. See `expectations.json` for original provenance.

Additional source-authored fixtures and the generation script are retained in
`/Users/levi/dev/nuxie-codex/codex-sdk-combined-base-notes/fit-content/edges`.
The writer uses the runtime proof's pinned upstream generated property keys
and field types; it does not edit or rebuild either runtime.

- `fill-child.riv`: the child fills root height. Upstream C++ and the retained
  port probe observe Hug height 32 (padding only), child height 0, at both
  widths. Fixed 600 yields child 568; Fixed 700 yields child 668.
- `tall-child.riv`: fixed child 1200. Both probes observe Hug height 1232.
  Native sheet sizing caps this at the system's large detent.
- `dynamic-child.riv`: local Root.contentHeight binds the child height using
  source path [1,0]. Source arithmetic: 120 -> 152, 240 -> 272. The screen test
  changes the real local model, steps, resizes and restores Fixed.
- `wrapping-children.riv`: six fixed 140 x 120 children in a wrapping row,
  root padding 16 top and bottom. Upstream C++ and port probes observe
  width 300 -> three rows -> 392; width 500 -> two rows -> 272.

The extra fixtures are isolated layout proofs, not published Experiences.
None has a painted frame-sized background. Background pixels and qualification
of a real compiler-published screen remain unproved.

## Reserved-name adaptation

The coordinator settled `$nuxie.presentation` / `heightMode` on 2026-10-07.
`proof/` retains the original proof bytes. The SDK-facing files at this folder's
root change only the single length-prefixed `Presentation` string to the
reserved global name. No indices, layout records, binding paths or expectations
change. SHA256SUMS includes both sets. Temporary SDK constants are explicitly
authorized until the coordinator names the shared declaration's commit.
