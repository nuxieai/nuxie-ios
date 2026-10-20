# Rules on values in state

SDK-authored fixture, generated without a publisher or runtime build. Regenerate with `python3 generate.py`. Both SDKs keep identical bytes.

A release that declares rules on values in `state` carries them in an optional top-level `stateRules` list, beside `state`, `responses` and `ruleGroups`. A release with none leaves the key out. Each record has the same fields as a form field's rule and names a value as the file holds it: a property of the `Experience` model, of a screen's `vm_runtime_root_<artboard>.state` model or of a group's model (`Experience.profile`), a component's own `state:<name>` on its `<artboard>::props` model, or a choice that allows several by its container model's `options` list with `picked` as the picked flag.

Every state rule refuses (mode 1), minimums and formats included: a value outside a form has no form to mark invalid (spec decision 119). Allowed values, required and item counts are not state rules.

`stateRules` must validate and install with the form rules, in one native table. Each `refused` case changes one accepted rule and must fail release validation. `engine` installs the first two rules on the published F4 screen (`trip_days` on the Experience model, at least 1 and at most 30) and writes each value in order: a write that breaks a rule keeps the last value that kept them.
