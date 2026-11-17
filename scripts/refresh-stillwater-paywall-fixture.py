#!/usr/bin/env python3
"""Refresh Tests/NuxieMachineTests/Fixtures/stillwater-paywall from a parent
checkout.

Usage: scripts/refresh-stillwater-paywall-fixture.py <parent checkout>
    --nux <the parent's Stillwater .nux folder> [--published <dir>]

The fixture's provenance.json records the parent's publish command and the
folder it publishes. This script publishes the Screen with that command (or
takes an earlier output of it at the same commit with --published), copies
the published Screen and Stillwater's four `.nux` files in from the folder
given, and rewrites provenance.json with the parent commit, each `.nux`
file's git blob id there, and a SHA-256 of each file. Everything it reads
from the parent must be committed and unchanged.
"""

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests/NuxieMachineTests/Fixtures/stillwater-paywall"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(parent: Path, *arguments: str) -> str:
    return subprocess.run(["git", "-C", str(parent), *arguments], check=True,
                          capture_output=True, text=True).stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("parent", type=Path)
    parser.add_argument("--nux", type=Path, required=True,
                        help="the folder in the parent checkout that holds Stillwater's .nux files")
    parser.add_argument("--published", type=Path,
                        help="an existing output folder of the publish command at the parent's commit")
    args = parser.parse_args()
    parent = args.parent.resolve()
    provenance_path = FIXTURE / "provenance.json"
    provenance = json.loads(provenance_path.read_text())
    publish = provenance["publish"]
    nux = args.nux.resolve()
    if not nux.is_relative_to(parent):
        sys.exit("The .nux folder must be inside the parent checkout")
    nux_folder = nux.relative_to(parent).as_posix()
    changed = git(parent, "status", "--porcelain", "--", publish["source"], nux_folder)
    if changed:
        sys.exit("The parent's fixture sources have uncommitted changes:\n" + changed)

    with tempfile.TemporaryDirectory() as temporary:
        published = args.published.resolve() if args.published else Path(temporary) / "published"
        if not args.published:
            command = [str(parent / publish["source"]) if part == "<source>" else
                       str(published) if part == "<output>" else part for part in publish["command"]]
            subprocess.run(command, cwd=parent, check=True)
        report = json.loads((published / "report.json").read_text())
        if sha256(published / "screen.riv") != report["outputSha256"]:
            sys.exit("The published screen.riv does not match its report")

        for name, entry in provenance["files"].items():
            if "published" in entry:
                source = published / entry["published"]
            else:
                source = nux / name
                entry["parentBlob"] = git(parent, "rev-parse", "HEAD:" + nux_folder + "/" + name)
            shutil.copyfile(source, FIXTURE / name)
            entry["sha256"] = sha256(FIXTURE / name)
            entry["sizeBytes"] = (FIXTURE / name).stat().st_size

    screens = report["builtPackageMetadata"]["screens"]
    if len(screens) != 1:
        sys.exit("The published Experience must hold exactly one Screen")
    source_folder = parent / publish["source"]
    provenance["parentCommit"] = git(parent, "rev-parse", "HEAD")
    publish["sourceFiles"] = {
        path: {"sha256": sha256(parent / path), "sizeBytes": (parent / path).stat().st_size}
        for path in git(parent, "ls-files", "--", publish["source"]).splitlines()
        if (parent / path).is_relative_to(source_folder)
    }
    provenance["artboard"] = screens[0]["artboardName"]
    provenance["reportedEventNames"] = screens[0]["reportedEventNames"]
    provenance["fonts"] = [
        {key: font[key] for key in ("family", "weight", "style", "authoredAssetId", "assetUniqueName", "location")}
        for font in report["builtPackageMetadata"]["assets"]["fonts"]
    ]
    provenance_path.write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Refreshed {FIXTURE.relative_to(ROOT)} from {provenance['parentCommit']}")


if __name__ == "__main__":
    main()
