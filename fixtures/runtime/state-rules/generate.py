"""SDK-authored state-rule policy fixture. No publisher or runtime build needed."""
from pathlib import Path
import copy
import json

EMAIL = r"[a-zA-Z0-9\.\!\#\$\%\&'\*\+\/\=\?\^_\`\{\|\}\~\-]+@[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*"
REFUSE = 1


def rule(model, prop, kind, code, message, **operands):
    record = {
        "model": model, "property": prop, "kind": kind, "mode": REFUSE,
        "number_bound": 0.0, "text": "", "values": [], "value_count": 0,
        "picked_property": "", "bound_flags": 0, "minimum": 0, "maximum": 0,
        "code": code, "message": message,
    }
    record.update(operands)
    return record


EXPERIENCE = "Experience"
SCREEN = "vm_runtime_root_scr_screens_splan.state"
GROUP = "Experience.profile"
CHOICES = 'vm_declared_list:multi_select:experience/"interests"'
COMPONENT = "cmp_components_sstepper::props"

STATE_RULES = [
    rule(EXPERIENCE, "trip_days", 1, "min", "Enter a larger number.", number_bound=1.0),
    rule(EXPERIENCE, "trip_days", 2, "max", "Enter a smaller number.", number_bound=30.0),
    rule(SCREEN, "code", 8, "minLength", "Enter more characters.", bound_flags=1, minimum=2),
    rule(SCREEN, "code", 8, "maxLength", "Enter fewer characters.", bound_flags=2, maximum=8),
    rule(SCREEN, "email", 9, "format", "Enter an email address.", text=EMAIL),
    rule(SCREEN, "site", 11, "format", "Enter a valid URL."),
    rule(SCREEN, "code", 9, "pattern", "Use the requested format.", text="[a-z]+"),
    rule(GROUP, "birthday", 3, "min", "Choose a later date.", text="1900-01-01"),
    rule(GROUP, "birthday", 4, "max", "Choose an earlier date.", text="2026-12-31"),
    rule(GROUP, "birthday", 12, "date", "Enter a real date in YYYY-MM-DD format."),
    rule(CHOICES, "options", 7, "minItems", "Choose more options.", picked_property="picked", bound_flags=1, minimum=1),
    rule(CHOICES, "options", 7, "maxItems", "Choose fewer options.", picked_property="picked", bound_flags=2, maximum=2),
    rule(COMPONENT, "state:count", 1, "min", "Enter a larger number.", number_bound=1.0),
]


def variant(case, index, **changes):
    changed = copy.deepcopy(STATE_RULES[index])
    changed.update(changes)
    return {"case": case, "rule": changed}


REFUSED = [
    variant("a minimum that only marks", 0, mode=0),
    variant("a maximum that only marks", 1, mode=0),
    variant("allowed values belong to forms", 0, kind=5, code="values", number_bound=0.0, values=["a"], value_count=1),
    variant("required belongs to forms", 0, kind=10, code="required", number_bound=0.0),
    variant("item count is not a state rule", 10, kind=6, code="minItems", picked_property=""),
    variant("a path instead of a property", 7, property="profile/birthday"),
    variant("an item count on another list", 10, property="picks"),
    variant("an item count without its picked flag", 10, picked_property=""),
    variant("a format with the wrong code", 5, code="url"),
    variant("a pattern with no pattern", 6, text=""),
    variant("a number bound on text", 2, number_bound=1.0),
    variant("a rule with no model", 0, model=""),
    variant("a rule with no message", 0, message=""),
]

# The published F4 screen holds trip_days on the Experience model.
ENGINE = {
    "screen": "../run-values/screen.riv",
    "rules": STATE_RULES[:2],
    "property": "trip_days",
    "writes": [
        {"value": 12, "kept": 12},
        {"value": 0, "kept": 12},
        {"value": 31, "kept": 12},
        {"value": 30, "kept": 30},
        {"value": 1, "kept": 1},
    ],
}

out = {"stateRules": STATE_RULES, "refused": REFUSED, "engine": ENGINE}
Path(__file__).with_name("policy.json").write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
