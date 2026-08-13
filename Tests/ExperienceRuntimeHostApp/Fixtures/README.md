# SDK runtime release fixtures

This directory contains the minimal descriptor-release set used by SDK tests
and reference hosts. Each fixture binds an exact signed envelope to standalone
RIV and content-addressed assets. `fixture-index.json` is the authority for the
committed fixture IDs and their SDK behavior roles.

Regeneration is owned by the parent repository's iOS E2E harness. Its refresh
target selects the SDK cases, assigns neutral SDK-owned identities, signs each
descriptor with the deterministic test-only development key, and copies verified
external assets into this directory. Product qualification fixtures remain in
the parent harness and are not copied here.
