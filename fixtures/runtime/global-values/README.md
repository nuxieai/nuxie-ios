# Named global-binding fixture

Exported without changing the fixture generator from commit
`3bbd68e35e8c6f7aa1423c5336203f62fdc58b50`, branch
`levi/runtime-global-fixture-names`, in the user-named clone
`/Users/levi/dev/nuxie-codex/runtime-global-fixture` only.
Index 0 is GlobalValuesRow; index 1 is GlobalValuesScreen. All index references
and bindings are unchanged. SDK tests select GlobalValuesScreen by exact name.

Oracle: the runtime owner's global_set_and_clear_reach_screen_copy_and_list_row
case asserts three labels, each "1" after binding Flags.enabled=true, each "0"
after clearing. Boolean conversion follows pinned upstream Rive's 1/0 rendering.
The refusal case requires failed replacement to retain the prior live binding.

`provenance.json` records the exact commit, exporter commands and binary SHA256.
Exporter source and schema copied with git show at that commit are retained in
`/Users/levi/dev/nuxie-codex/codex-sdk-combined-base-notes/global-matrix`.
This is test support only. No runtime source, staged library or pin was changed.
