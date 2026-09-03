# Nuxie Experience Runtime Reference App

Native iOS host for the signed Journey release contract. It
depends on the customer SDK target, authenticates the exact inline envelope,
acquires its content-addressed RIV and assets, imports the scene through the
final `nux_experience_context_*` ABI, and does not ship a Rive dependency.

The app bundles two neutral SDK-owned contract fixtures:

- `animation-event`
- `multi-screen`

Build and audit it with:

```sh
make build-reference-app
make test-runtime-reference-ui
```

The UI gate waits for `presented:animation-event`, emitted only after the
release has passed signature/identity admission, object integrity checks, and
runtime context creation.
