#!/usr/bin/env python3
"""Verify the shipped declaration against its pinned source digest (and optional source checkout)."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
provenance = json.loads((root / "docs/presentation-schema-provenance.json").read_text())
resource = (root / provenance["resourcePath"]).read_bytes()
assert hashlib.sha256(resource).hexdigest() == provenance["sha256"], "Presentation resource digest changed"
if len(sys.argv) > 1:
    source = subprocess.check_output(["git", "show", provenance["sourceCommit"] + ":" + provenance["sourcePath"]], cwd=sys.argv[1])
    assert resource == source, "Presentation resource differs from the pinned canonical declaration"
print("Presentation schema matches " + provenance["sourceCommit"])
