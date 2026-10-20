#!/usr/bin/env python3
"""Print the release notes for one version from CHANGELOG.md.

The section starts at a heading of the form "## X.Y.Z" or
"## X.Y.Z (YYYY-MM-DD)" and runs to the next "## " heading. A section still
headed "## X.Y.Z (unreleased)", a repeated heading, or an empty section is
refused, so a published release never carries notes that say "unreleased".
"""

import datetime
import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"changelog-section: {message}")


if len(sys.argv) != 3:
    fail("usage: changelog-section.py CHANGELOG.md X.Y.Z")

changelog_path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
try:
    lines = changelog_path.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError) as error:
    fail(f"cannot read {changelog_path}: {error}")

heading = f"## {version}"
starts = [
    index
    for index, line in enumerate(lines)
    if line == heading or line.startswith(heading + " ")
]
if not starts:
    fail(f"{changelog_path.name} has no '{heading}' section")
if len(starts) > 1:
    fail(f"{changelog_path.name} has more than one '{heading}' section")

start = starts[0]
suffix = lines[start][len(heading):]
if suffix == " (unreleased)":
    fail(
        f"'{heading}' is still marked unreleased; the release pull request "
        "replaces '(unreleased)' with the release date"
    )
if suffix:
    date = re.fullmatch(r" \((\d{4}-\d{2}-\d{2})\)", suffix)
    if date is None:
        fail(
            f"heading must be '{heading}' or '{heading} (YYYY-MM-DD)', "
            f"not '{lines[start]}'"
        )
    try:
        datetime.date.fromisoformat(date.group(1))
    except ValueError:
        fail(f"'{lines[start]}' does not carry a real date")

end = next(
    (
        index
        for index in range(start + 1, len(lines))
        if lines[index].startswith("## ")
    ),
    len(lines),
)
body = lines[start + 1:end]
while body and not body[0].strip():
    body.pop(0)
while body and not body[-1].strip():
    body.pop()
if not body:
    fail(f"'{heading}' section is empty")

print("\n".join(body))
