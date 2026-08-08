#!/usr/bin/env python3

import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.parse


def fail(message: str) -> None:
    raise SystemExit(f"runtime-package-pin: {message}")


if len(sys.argv) != 2:
    fail("usage: check-runtime-package-pin.py Runtime/artifact.json")

metadata_path = pathlib.Path(sys.argv[1])
try:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"cannot read {metadata_path}: {error}")

if set(metadata) != {"release", "url", "checksum"}:
    fail("artifact metadata must contain exactly release, url, and checksum")
if not all(isinstance(metadata[key], str) for key in metadata):
    fail("artifact metadata values must be strings")
if re.fullmatch(r"[0-9a-f]{64}", metadata["checksum"]) is None:
    fail("checksum is not a lowercase SHA-256")

parsed_url = urllib.parse.urlsplit(metadata["url"])
expected_prefix = f"/nuxieai/nuxie-runtime/releases/download/{metadata['release']}/"
if (
    parsed_url.scheme != "https"
    or parsed_url.netloc != "github.com"
    or not parsed_url.path.startswith(expected_prefix)
    or not parsed_url.path.endswith(".zip")
    or parsed_url.query
    or parsed_url.fragment
):
    fail("URL is not an immutable nuxie-runtime release asset")

environment = dict(os.environ)
environment["NUXIE_RUNTIME_USE_RELEASE"] = "1"
try:
    manifest = json.loads(
        subprocess.run(
            ["swift", "package", "dump-package"],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
            env=environment,
        ).stdout
    )
except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
    fail(f"cannot inspect Package.swift: {error}")

targets = [target for target in manifest.get("targets", []) if target.get("name") == "NuxieRuntimeFFI"]
if len(targets) != 1:
    fail("Package.swift must declare exactly one NuxieRuntimeFFI target")
target = targets[0]
if target.get("type") != "binary" or target.get("path") is not None:
    fail("NuxieRuntimeFFI must be a remote binary target in release mode")
if target.get("url") != metadata["url"] or target.get("checksum") != metadata["checksum"]:
    fail("Package.swift binary target differs from Runtime/artifact.json")

print(f"Runtime package pin passed: {metadata['release']} URL and checksum are atomic")
