#!/usr/bin/env python3
"""Retain authored #filePath values only for the source-based test suites."""

import json
from pathlib import Path
import sys


def map_sources(manifest):
    root = Path(manifest["root"])
    if not root.is_absolute():
        raise ValueError("Test source paths require an absolute SDK checkout")
    for source, logical, destination in manifest["sources"]:
        relative = Path(logical)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("The test source must belong to the SDK checkout")
        location = json.dumps(str(root / relative), ensure_ascii=False)
        output = Path(destination)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(('#sourceLocation(file: ' + location + ', line: 1)\n').encode() + Path(source).read_bytes())


if __name__ == "__main__":
    map_sources(json.loads(Path(sys.argv[1]).read_text()))
