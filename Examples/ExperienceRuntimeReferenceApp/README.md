# Nuxie Experience Runtime Reference App

Native iOS host for the signed `.nux` package contract. It depends on the
customer SDK target, imports each package through the final
`nux_experience_context_*` ABI, and does not ship a Rive dependency.

The app bundles two generated production-contract fixtures:

- `animation-event`
- `multi-screen`

Build and audit it with:

```sh
make build-reference-app
make test-runtime-reference-ui
```

The UI gate waits for `presented:animation-event`, emitted only after the
package has passed pointer hashing, signature/identity authentication, and
runtime context creation.
