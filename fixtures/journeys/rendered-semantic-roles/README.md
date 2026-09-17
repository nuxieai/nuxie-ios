# Signed authored semantic roles candidate

Generated through the production Journey release compiler in the parent repository.
`provenance.json` records the publisher commit, source/publish snapshot hashes,
signed descriptor digest, and explicit test public key. The render and font bytes
are acquired through the signed entry's content-addressed references.

This candidate requires `experience-accessibility`; default SDK admission must reject it
until platform qualification is complete. Generator tests verify secure-value
redaction, response binding, native geometry paths, and font identity. The fixture
alone does not prove native adapter behavior or VoiceOver/TalkBack qualification.

The authored controls cover a level-two heading, ordinary Text, button, selected
checked checkbox, required mixed checkbox, adjustable seats with an authored value,
a secure editable password, disabled button, decoration, and repeated list items.
Increase/decrease emit `seat_increased` and `seat_decreased`; password edits target
the required `password` response field. Continue and checkbox have no authored
activation action, so consumers must not invent one.
