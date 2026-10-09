# Choices set fixture

Canonical source for [UNIV-4130](https://universe.basis.dev/issue/UNIV-4130). The browser-host regression reads these same source files. `expectations.json` is handwritten before publication.

The Save button makes three calls in order: set picks to b and c, set picks to b, then set picks to nil. The field allows at most one pick and starts with a picked. Each call reports `checked` with `ok` and, on refusal, `rule`. The first call must report maxItems and retain a; the second keeps only b; the third unpicks all three records without removing them. The visible option labels let the editor regression check that the list still contains all three records.

The helper requires the runtime's generic listValues and setAll functions. The compiler, editor host and platform runtime pins ship together. This fixture does not qualify older runtimes, single-choice-by-name behavior or platform script-error recovery.

The retained release and screen were published through the real publisher and signed-fixture harness, with the Step 3 compiler. `provenance.json` records the compiler and wasm identities and every retained file hash. The native host checks all three taps against this same canonical source. Both SDKs must receive these identical bytes; this task does not edit SDK repositories.

The development qualification used runtime facade e1fad62dff. The final runtime release pointer and platform gates remain with their owners. These bytes require the new runtime helpers and must not ship ahead of those pins.
