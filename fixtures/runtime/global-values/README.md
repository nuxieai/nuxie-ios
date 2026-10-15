# Named global-binding fixture

Exported without changing the fixture generator from commit
`3bbd68e35e8c6f7aa1423c5336203f62fdc58b50`, branch
`levi/runtime-global-fixture-names`, in the `nuxie-runtime` repository.
The builder is `crates/nux-capi/tests/support/global_values.rs`, function
`fixture(false)`. In the parent repository (`nuxie-dev`), that runtime path is
under `third_party/nuxie-runtime/`; the historical commit above selects the
bytes exported here.
Index 0 is GlobalValuesRow; index 1 is GlobalValuesScreen. All index references
and bindings are unchanged. SDK tests select GlobalValuesScreen by exact name.

Oracle: the runtime owner's global_set_and_clear_reach_screen_copy_and_list_row
case asserts three labels, each "1" after binding Flags.enabled=true, each "0"
after clearing. Boolean conversion follows pinned upstream Rive's 1/0 rendering.
The refusal case requires failed replacement to retain the prior live binding.

`provenance.json` records the exact commit, exporter commands and binary SHA256.
Commands use paths relative to the historical export directory: `source/` held
files from that commit, and `export.rs` was a test-only wrapper that wrote
`global_values::fixture(false)` to its first argument. The wrapper was retained
in the historical handoff, not committed as a parent repository tool.
This is test support only. No runtime source, staged library or pin was changed.
