# SDK runtime package fixtures

This directory contains the minimal signed package set used by SDK tests and
reference hosts. `fixture-index.json` is the authority for the committed
fixture IDs and their SDK behavior roles.

Regeneration is owned by the parent repository's iOS E2E harness. Its refresh
target selects the SDK cases, assigns neutral SDK-owned identities, signs each
package with the deterministic test-only development key, and copies verified
external assets into this directory. Product qualification fixtures remain in
the parent harness and are not copied here.
