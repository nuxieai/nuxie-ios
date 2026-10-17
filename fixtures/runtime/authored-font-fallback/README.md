# Ordinary authored text baseline

P038 / [UNIV-3375](https://universe.basis.dev/issue/UNIV-3375).

`ordinary-roboto.nux` was emitted by the publisher example at `be00893bb0`.
`ordinary-provenance.json` records its source and output hashes, font
declaration, strings and row positions. The scene contains ordinary Text
nodes, with no TextInput or platform editing overlay. Its primary font is the
Latin-only `ordinary-latin.ttf`, so every non-Latin row needs fallback.

The System font stays external. Its private source bytes are not present here.
`ordinary-latin.ttf` is the same Apache-licensed Roboto fixture as
`Tests/NuxieUnitTests/Fixtures/ordinary_font_fallback_latin.ttf`; its license is
in `Tests/NuxieUnitTests/Fixtures/LICENSE-ordinary-font-fallback.txt`.

The published-text regression observes the actual C fallback hook and compares
its selected PostScript names with CoreText. It also checks visible native ink.
The typed two-field form qualifies Japanese, Arabic, Hebrew, Hindi, Latin,
emoji and symbols after focus moves. Ordinary and typed emoji must contain
saturated colour ink on every OS version. CoreText supplies PNG glyph pictures
for colour fallback faces, including Apple emjc strikes that the runtime cannot
decode itself; monochrome outlines do not satisfy the emoji checks.
Outline glyphs within a colour face (such as `#` and unpaired regional
indicators) keep using the text-colour path callback. A picture is accepted
only when its pixels are identical under black and white CoreText fills.
