# Ordinary authored text baseline

P038 / [UNIV-3375](https://universe.basis.dev/issue/UNIV-3375).

These two files were emitted by the real superproject publisher example
`tools/nuxie-editor/crates/publisher-wasm/examples/font_fallback_fixture.rs`
at `be00893bb0`. `ordinary-provenance.json` records source and output hashes,
font declarations, strings and row positions. The scenes contain ordinary
Text nodes, with no TextInput or platform editing overlay.

The System font stays external. Its private source bytes are not present here.
`ordinary-latin.ttf` is the same Apache-licensed Roboto fixture as
`../ordinary_font_fallback_latin.ttf`; its license is in
`../ordinary_font_fallback_latin.LICENSE`.

The XCTest baseline records native Metal frames for both authored faces.
It is an observation, not a claim that fallback already works. Run the
published-text test together with the separately generated ordinary native
control before installing any P038 catalog.
