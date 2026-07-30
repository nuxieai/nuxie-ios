#!/usr/bin/env python3

import json
import pathlib
import sys
import unicodedata


def fail(message: str) -> None:
    raise SystemExit(f"json-scalar: {message}")


if len(sys.argv) != 4:
    fail("usage: json-scalar.py <json-file|-> <top-level-key> <integer|string>")

source = sys.argv[1]
key = sys.argv[2]
expected_type = sys.argv[3]
if expected_type not in {"integer", "string"}:
    fail(f"unsupported expected type {expected_type!r}")

try:
    if source == "-":
        document = json.load(sys.stdin)
    else:
        with pathlib.Path(source).open(encoding="utf-8") as input_file:
            document = json.load(input_file)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"cannot read {source}: {error}")

if not isinstance(document, dict):
    fail(f"{source} does not contain a top-level object")
if key not in document:
    fail(f"{source} does not contain key {key!r}")

value = document[key]
if expected_type == "integer":
    if type(value) is not int:
        fail(f"{source} key {key!r} is not an integer")
else:
    if not isinstance(value, str):
        fail(f"{source} key {key!r} is not a string")
    if any(unicodedata.category(character) == "Cc" for character in value):
        fail(f"{source} key {key!r} contains a control character")

print(value)
