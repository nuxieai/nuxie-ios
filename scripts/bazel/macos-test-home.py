#!/usr/bin/env python3
"""Give Foundation a writable home inside this macOS test's sandbox."""

import os
from pathlib import Path
import plistlib
import stat


def configure_home(test_tmpdir: Path) -> Path:
    scratch = test_tmpdir.resolve(strict=True)
    # rules_apple's supported pre_action runs after preparing this private file.
    candidates = list(scratch.glob("test_tmp_dir.*/tests.xctestrun"))
    if len(candidates) != 1 or not candidates[0].resolve().is_relative_to(scratch):
        raise ValueError("Expected one runner-owned macOS xctestrun inside TEST_TMPDIR")
    xctestrun = candidates[0]
    configuration = plistlib.loads(xctestrun.read_bytes())
    targets = [target for target in configuration.values()
               if isinstance(target, dict) and "TestingEnvironmentVariables" in target]
    if len(targets) != 1 or not isinstance(targets[0]["TestingEnvironmentVariables"], dict):
        raise ValueError("Expected one macOS test environment")
    home = xctestrun.parent / "private-home"
    home.mkdir()
    targets[0]["TestingEnvironmentVariables"].update({
        "HOME": str(home),
        "CFFIXED_USER_HOME": str(home),
        "NUXIE_MACOS_TEST_HOME": str(home),
        "NUXIE_MACOS_TEST_TMPDIR": str(scratch),
    })
    # cp preserves the read-only generated template's mode. This is its owned
    # scratch copy, never the declared template or a file in shared runfiles.
    xctestrun.chmod(xctestrun.stat().st_mode | stat.S_IWUSR)
    xctestrun.write_bytes(plistlib.dumps(configuration))
    return home


if __name__ == "__main__":
    configure_home(Path(os.environ["TEST_TMPDIR"]))
