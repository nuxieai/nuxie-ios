#!/usr/bin/env python3
"""Optional cache transport and an endpoint-bound Bazel credential helper."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import urlsplit


PREFIX = "NUXIE_BAZEL_REMOTE_CACHE_"
spec = importlib.util.spec_from_file_location("cache_tls_pin", Path(__file__).with_name("cache-tls-pin.py"))
tls_pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tls_pin)


def parse_endpoint(raw):
    parsed = urlsplit(raw)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or not re.fullmatch(r"[A-Za-z0-9.-]+", parsed.hostname)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("cache URL must be a credential-free HTTPS origin")
    # Validate the port without printing the supplied URL.
    port = parsed.port if parsed.port is not None else 443
    if not 1 <= port <= 65535:
        raise ValueError("invalid cache endpoint port")
    return parsed.hostname.lower(), port, raw.rstrip("/")


def endpoint():
    return parse_endpoint(os.environ.get(PREFIX + "URL", ""))


def credential():
    path = Path(os.environ.get(PREFIX + "CREDENTIAL_FILE", ""))
    if not path.is_absolute():
        raise ValueError("cache credential file must be absolute")
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError("cache credential path must not contain symlinks")
    parent_info = path.parent.stat()
    if parent_info.st_uid != os.getuid() or stat.S_IMODE(parent_info.st_mode) & 0o077:
        raise ValueError("cache credential directory must be owned and private (0700)")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077
            or info.st_nlink != 1
            or info.st_size > 16384
        ):
            raise ValueError("cache credential file must be singly linked, owned and private (0600)")
        data = json.loads(stream.read(16385))
    if not isinstance(data, dict) or set(data) != {"endpoint", "username", "password"}:
        raise ValueError("cache credential file must contain endpoint, username and password")
    if not all(isinstance(data[k], str) and data[k] for k in data):
        raise ValueError("cache credential values must be nonempty strings")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", data["username"]):
        raise ValueError("invalid cache credential username")
    if any(c in data["password"] for c in "\r\n\x00"):
        raise ValueError("invalid cache credential password")
    if parse_endpoint(data["endpoint"])[:2] != endpoint()[:2]:
        raise ValueError("cache credential endpoint must match the configured origin")
    return data


def ca_file():
    return tls_pin.validate(os.environ.get(PREFIX + "TLS_PIN_FILE", ""), os.environ.get(PREFIX + "URL", ""), os.environ.get(PREFIX + "CA_FILE", ""))


def flags():
    mode = os.environ.get(PREFIX + "MODE", "off")
    if mode == "off":
        # An explicit off mode overrides a user/host rc; absent mode preserves it.
        return ["--remote_cache="] if PREFIX + "MODE" in os.environ else []
    if mode not in ("read", "write"):
        raise ValueError("cache mode must be off, read or write")
    if os.environ.get(PREFIX + "ELIGIBLE") != "1":
        raise ValueError("cache enablement requires proven action eligibility")
    domain = os.environ.get(PREFIX + "DOMAIN", "")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", domain):
        raise ValueError("cache domain must be a pinned sha256 toolchain fingerprint")
    host, _, origin = endpoint()
    certificate = ca_file()
    credential()
    helper = str(Path(__file__).resolve())
    return ["--tls_certificate=" + certificate] + [
        "--remote_cache=" + origin,
        "--remote_max_connections=1",
        "--remote_upload_local_results=" + str(mode == "write").lower(),
        "--action_env=NUXIE_BAZEL_REMOTE_CACHE_DOMAIN=" + domain,
        "--credential_helper=" + host + "=" + helper,
        "--credential_helper_timeout=2s",
        "--credential_helper_cache_duration=0s",
        "--remote_timeout=10s",
        "--remote_retries=1",
        "--remote_retry_max_delay=1s",
        "--remote_verify_downloads=true",
        "--remote_local_fallback=true",
        "--incompatible_remote_local_fallback_for_remote_cache=true",
    ]


def get():
    mode = os.environ.get(PREFIX + "MODE", "off")
    if mode == "off":
        return {}
    if mode not in ("read", "write") or os.environ.get(PREFIX + "ELIGIBLE") != "1" or not re.fullmatch(r"sha256:[a-f0-9]{64}", os.environ.get(PREFIX + "DOMAIN", "")):
        raise ValueError("credential requests require enabled eligible cache transport")
    request = json.loads(sys.stdin.read(16384))
    uri = urlsplit(request.get("uri", ""))
    host, port, _ = endpoint()
    if (
        uri.scheme != "https"
        or uri.hostname != host
        or (uri.port if uri.port is not None else 443) != port
        or uri.username is not None
        or uri.password is not None
        or uri.query
        or uri.fragment
        # Bazel 9.3 HTTP cache requests credentials for the configured origin.
        or (uri.path not in ("", "/") and not re.fullmatch(r"/(ac|cas)/[a-f0-9]{64}", uri.path))
    ):
        return {}
    ca_file()
    data = credential()
    token = base64.b64encode((data["username"] + ":" + data["password"]).encode()).decode()
    return {"headers": {"Authorization": ["Basic " + token]}}


def main():
    try:
        command = sys.argv[1] if len(sys.argv) == 2 else ""
        if command == "flags":
            for flag in flags():
                print(flag)
        elif command == "get":
            print(json.dumps(get()))
        else:
            raise ValueError("expected flags or get")
    except (ValueError, OSError, TypeError, AttributeError):
        # Never include secret values, input JSON or file contents in diagnostics.
        print("Bazel remote cache configuration or credential request is invalid", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
