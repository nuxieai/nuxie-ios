# F.6: a tap runs an action script

A 300 × 300 screen has an Increment button at (20, 20), size 160 × 60,
and a count label at (20, 120). The button runs `run(increment)`; the linked
`scripts/increment.luau` action adds one to the screen's `state.count`.
The independent oracle is 0 initially, then 1, 2 and 3 after three taps at
(100, 50). The label must show the same numbers. There is no save, emit,
network callback, or second value store.

`release.json` is the exact signed descriptor from the real publisher;
`profile-entry.json` retains its envelope and locator. `screen.riv` contains
the same bytes as the single content-addressed render object. This is local
fixture publication using the repository test signing key, not a deployment.
See `provenance.json` for the source commit, publisher, authority and script
compiler hashes, pinned runtime, and hashes and sizes of all delivered files.
The declared System font remains external; platform font and pixel proof
belong to the SDK runs.

## Platform proof (Thread 4)

Copy this folder byte for byte to each SDK's `fixtures/runtime/script-tap`,
following the C11 provenance convention; update Android's fixture manifest.
Verify every recorded hash and explicitly trust only the repository test
public key. Acquire the signed release through the SDK's normal path, load
its script resource and render, mount the screen and its native view model,
and tap the actual button on an iOS simulator and Android emulator.

Assert native `state/count` and visible text are 0, 1, 2, 3 in order. Use native
pointer taps, not direct Luau calls or test writes to the value. Check the
nearest existing script-resource and tap tests. A separately compiled +2
mutation must fail the handwritten first-tap expectation of 1; never mutate
signed bytes in place. SDK implementation and device execution are not
claimed by this fixture's publisher-side tests.
