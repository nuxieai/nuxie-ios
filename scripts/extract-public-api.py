#!/usr/bin/env python3
"""Extract a stable declaration allowlist from swift-api-digester JSON."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Iterator


def objects(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} API_DIGEST.json", file=sys.stderr)
        return 64

    with Path(sys.argv[1]).open(encoding="utf-8") as source:
        digest = json.load(source)

    declarations = {
        "\t".join((node["usr"], node["kind"], node.get("printedName", "")))
        for node in objects(digest)
        if node.get("moduleName") == "Nuxie"
        and isinstance(node.get("usr"), str)
        and node.get("implicit") is not True
    }
    for declaration in sorted(declarations):
        print(declaration)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
