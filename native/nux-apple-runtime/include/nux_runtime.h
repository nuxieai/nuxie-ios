#ifndef NUX_RUNTIME_H
#define NUX_RUNTIME_H

/* Product-shaped C ABI for Nuxie's Apple experience runtime. Declarations are
 * generated from Rust and verified during every build. Handles own or retain
 * their parents; destruction is null-safe and never requires a child-first
 * order to avoid memory unsafety. Calls may enter from arbitrary caller
 * threads; runtime state is internally serialized onto a pinned Rust worker.
 * Releasing a handle must not race a call that uses that same handle. */

#include "nux_runtime.generated.h"

#endif /* NUX_RUNTIME_H */
