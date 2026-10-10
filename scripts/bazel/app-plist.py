#!/usr/bin/env python3
"""Resolve the authored Xcode app version settings for native Bazel packaging."""

import plistlib
import sys
from pathlib import Path


def app_plist(data: bytes, marketing_version: str, build_version: str) -> bytes:
    plist = plistlib.loads(data)
    substitutions = {"MARKETING_VERSION": marketing_version, "CURRENT_PROJECT_VERSION": build_version}

    def replace(value):
        if isinstance(value, str):
            for key, setting in substitutions.items():
                value = value.replace("$(" + key + ")", setting).replace("${" + key + "}", setting)
        elif isinstance(value, dict):
            value = {key: replace(child) for key, child in value.items()}
        elif isinstance(value, list):
            value = [replace(child) for child in value]
        return value

    return plistlib.dumps(replace(plist), sort_keys=False)


if __name__ == "__main__":
    source, destination, marketing, build = sys.argv[1:]
    Path(destination).write_bytes(app_plist(Path(source).read_bytes(), marketing, build))
