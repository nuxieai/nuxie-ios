# Ordinary authored text baseline

P038 / [UNIV-3375](https://universe.basis.dev/issue/UNIV-3375).

These two files were emitted by the publisher example at `be00893bb0`.
`ordinary-provenance.json` records source and output hashes,
font declarations, strings and row positions. The scenes contain ordinary
Text nodes, with no TextInput or platform editing overlay.

The System font stays external. Its private source bytes are not present here.
`ordinary-latin.ttf` is the same Apache-licensed Roboto fixture as
`Tests/NuxieUnitTests/Fixtures/ordinary_font_fallback_latin.ttf`; its license is
in `Tests/NuxieUnitTests/Fixtures/LICENSE-ordinary-font-fallback.txt`.

The published-text regression observes the actual C fallback hook and compares
its selected PostScript names with CoreText. It also checks visible native ink.
The typed two-field form qualifies Japanese, Arabic, Hebrew, Hindi, Latin,
emoji and symbols after focus moves. Only iOS 27.0 currently checks the known
blank Apple emjc emoji row; other OS versions do not inherit that expectation.
