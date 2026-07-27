#!/usr/bin/env python3

import json
import subprocess
import sys

EXPECTED_RUNTIME_VERSION = "0.2.0"
EXPECTED_SOURCE_REVISION = "b1f58004332a73564ffdd9f8585838209604c4d1"
EXPECTED_RUNTIME_IDENTITY = (
    f"{EXPECTED_RUNTIME_VERSION}@{EXPECTED_SOURCE_REVISION}"
)


def provenance_records(payload: str) -> list[dict[str, object]]:
    decoder = json.JSONDecoder()
    records: list[dict[str, object]] = []
    for index, character in enumerate(payload):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(payload, index)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        if {
            "schemaVersion",
            "runtimeVersion",
            "sourceRevision",
            "runtimeIdentity",
        }.issubset(value):
            records.append(value)
    return records


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} /path/to/native-payload", file=sys.stderr)
        return 64

    payload_path = sys.argv[1]
    completed = subprocess.run(
        ["xcrun", "strings", payload_path],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        print(
            f"could not read native runtime provenance from {payload_path}",
            file=sys.stderr,
        )
        return 1

    records = provenance_records(completed.stdout)
    if len(records) != 1:
        print(
            f"{payload_path} has {len(records)} runtime provenance records; "
            "expected exactly one",
            file=sys.stderr,
        )
        return 1

    record = records[0]
    expected = {
        "schemaVersion": 2,
        "runtimeVersion": EXPECTED_RUNTIME_VERSION,
        "sourceRevision": EXPECTED_SOURCE_REVISION,
        "runtimeIdentity": EXPECTED_RUNTIME_IDENTITY,
    }
    mismatches = [
        f"{key}={record.get(key)!r} (expected {value!r})"
        for key, value in expected.items()
        if record.get(key) != value
    ]
    if mismatches:
        print(
            f"{payload_path} has the wrong exact runtime provenance: "
            + ", ".join(mismatches),
            file=sys.stderr,
        )
        return 1

    print(
        f"Validated {payload_path}: exact runtime provenance "
        f"{EXPECTED_RUNTIME_IDENTITY}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
