#!/usr/bin/env python3
"""Install the checksummed Bazelisk launcher and honor the workspace Bazel pin."""

import fcntl
import hashlib
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile
import urllib.request

VERSION = "1.27.0"
# Digests from bazelbuild/bazelisk's v1.27.0 GitHub release asset metadata.
DIGESTS = {
    "darwin-amd64": "8fcd7ba828f673ba4b1529425e01e15ac42599ef566c17f320d8cbfe7b96a167",
    "darwin-arm64": "8bf08c894ccc19ef37f286e58184c3942c58cb08da955e990522703526ddb720",
    "linux-amd64": "e1508323f347ad1465a887bc5d2bfb91cffc232d11e8e997b623227c6b32fb76",
    "linux-arm64": "bb608519a440d45d10304eb684a73a2b6bb7699c5b0e5434361661b25f113a5d",
}


def executable():
    target = platform.system().lower() + "-" + {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine(), platform.machine())
    if target not in DIGESTS:
        raise ValueError("The pinned Bazelisk launcher supports Linux/macOS on amd64/arm64")
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "nuxie-tools/bazelisk" / VERSION
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / ("bazelisk-" + target)
    def valid():
        return destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == DIGESTS[target]
    with (cache / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not valid():
            if shutil.disk_usage(cache).free < 5 * 1024**3:
                raise ValueError("Bazelisk installation needs at least 5 GiB of free disk")
            url = "https://github.com/bazelbuild/bazelisk/releases/download/v" + VERSION + "/bazelisk-" + target
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read(24 * 1024**2 + 1)
            if len(data) > 24 * 1024**2 or hashlib.sha256(data).hexdigest() != DIGESTS[target]:
                raise ValueError("Pinned Bazelisk download failed its size or SHA-256 check")
            with tempfile.NamedTemporaryFile(prefix=".install-", dir=cache, delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(data)
            try:
                temporary.chmod(0o755)
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
    return str(destination)


if __name__ == "__main__":
    try:
        candidate = executable()
        os.execv(candidate, [candidate, *sys.argv[1:]])
    except (ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
