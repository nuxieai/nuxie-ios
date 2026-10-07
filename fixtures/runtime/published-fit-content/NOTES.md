# Fit-content compiler fixture

The source folder contains real Experience files. The publisher example loads them through experience-editor-bridge Pipeline, obtains the document snapshot, then calls editor_publisher_wasm::publish, including resource and roundtrip validation. The bound fixture bytes are asserted equal to that full publisher output. The control preserves the publisher header and removes only the root-height binding records. No expected height is read from the published artifact.

The sheet has 16 pixels of top padding, a fixed 120-pixel child, and 16 pixels of bottom padding. Its independent expected Hug height is 152, at widths 300 and 500. Fixed uses the supplied 700. A second player remains 500 by 700 throughout. Both Fixed-first and Hug-first runs return to the sheet after the edge screens. Every newly created presentation instance defaults to Fixed.

The control removes only root-height DataBindContext records targeting property 656. It must remain 700 in both modes. The negative native regression removes this same binding while still expecting 152, and fails at 700 versus 152. No pixel baseline is changed.

Upstream observations: the fill-height child has no intrinsic height, so Hug leaves only the 32 pixels of padding. The absolute frame-sized background does not contribute to flow, so that screen stays 152 in Hug; its background still has the authored 700-pixel rectangle. These are observations, not new compiler layout rules.

The upstream C++ and public C API probes agree on all 192 measured primary-player observations, and assert the independent player's unchanged height on every step. The C API uses the runtime owner's qualified bc0a7e7e5d96f328d675ed39142c7549711a8e39 checkout read only: the component branch's older runtime pin lacks the public global and layout-size APIs. No runtime source or submodule pointer changed. The native integration regression additionally uses the branch's own runtime pin.

Probes discover the presentation schema by its unique global name. That schema index is a locator, not an expected layout value. The source-derived expectations are in expectations.json. Exact compilation command arrays are retained in probes; paths refer to this machine's retained read-only upstream source and this thread's owned build outputs.

Run publication from the repository root using the optimized test helper in the compiler notes: bash <notes>/check.sh run -p experience-editor-bridge --example publish_presentation -- <fixture>/source <output>. Run each compiled probe with the RIV path, using the name no-binding.riv for the control and FIRST_HUG=1 for the reversed order. Logs and provenance record the exact qualified artifacts.
