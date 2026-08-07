#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

if rg -n '^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(NuxieRuntimeFFI|NuxieProductFFI)$' Sources/Nuxie; then
    echo "The Nuxie SDK imports the runtime FFI directly; import the Swift NuxieRuntime module instead." >&2
    exit 1
fi

if ! rg -q '^@_exported import NuxieRuntimeFFI$' Sources/NuxieRuntime/NuxieRuntime.swift; then
    echo "The legacy Swift FFI export changed; finish moving all raw C use behind NuxieRuntime before removing it." >&2
    exit 1
fi

python3 - <<'PY'
import pathlib
import re
import sys


source = pathlib.Path("Package.swift").read_text()


def closing_parenthesis(text: str, opening: int) -> int | None:
    depth = 0
    index = opening
    quote: str | None = None
    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if quote is not None:
            if character == "\\":
                index += 2
                continue
            if character == quote:
                quote = None
        elif character in {'"', "'"}:
            quote = character
        elif character == "/" and following == "/":
            newline = text.find("\n", index + 2)
            index = len(text) if newline < 0 else newline
            continue
        elif character == "/" and following == "*":
            closing = text.find("*/", index + 2)
            index = len(text) if closing < 0 else closing + 2
            continue
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None


def target_blocks(text: str) -> list[str]:
    blocks = []
    for match in re.finditer(r"(?<![A-Za-z0-9_])\.target\s*\(", text):
        opening = text.find("(", match.start(), match.end())
        closing = closing_parenthesis(text, opening)
        if closing is not None:
            blocks.append(text[match.start() : closing + 1])
    return blocks


def target_named(name: str) -> str | None:
    for block in target_blocks(source):
        match = re.search(r'\bname\s*:\s*"([^"]+)"', block)
        if match is not None and match.group(1) == name:
            return block
    return None


def has_ios_dependency(owner: str, dependency: str) -> bool:
    ios_condition = re.compile(
        r'\bcondition\s*:\s*\.when\s*\(\s*platforms\s*:\s*'
        r'\[\s*\.iOS\s*\]\s*\)'
    )
    opening = owner.find("(")
    for block in target_blocks(owner[opening + 1 :]):
        name = re.search(r'\bname\s*:\s*"([^"]+)"', block)
        if (
            name is not None
            and name.group(1) == dependency
            and ios_condition.search(block) is not None
        ):
            return True
    return False


required_edges = (
    ("NuxieRuntime", "NuxieRuntimeFFI"),
    ("Nuxie", "NuxieRuntime"),
)
for owner_name, dependency_name in required_edges:
    owner = target_named(owner_name)
    if owner is None or not has_ios_dependency(owner, dependency_name):
        print(
            f"{dependency_name} must remain an iOS-only dependency of "
            f"the {owner_name} target.",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY

if ! rg -q '^module NuxieRuntimeFFI \{' native/nux-apple-runtime/include/module.modulemap; then
    echo "The runtime XCFramework module map must expose only NuxieRuntimeFFI." >&2
    exit 1
fi

if rg -q '^module NuxieRuntime \{' native/nux-apple-runtime/include/module.modulemap; then
    echo "The binary module is shadowing the Swift NuxieRuntime module." >&2
    exit 1
fi

echo "Runtime module boundary passed: Nuxie -> Swift NuxieRuntime -> NuxieRuntimeFFI"
