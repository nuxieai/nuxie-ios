#!/usr/bin/env python3
"""Validate public, root-controlled cache leaf pins; create reviewed receipts."""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


TRUST_OWNER = 0
TRUST_ROOT = Path("/")
VALIDITY_MARGIN_SECONDS = 12 * 60 * 60
VALIDATION_TIMEOUT_SECONDS = 1.5
OPENSSL = "/usr/bin/openssl"
PEM_LIMIT = 262144
CERTIFICATE_LIMIT = 65536


def origin(value):
    if not isinstance(value, str) or len(value) > 4096 or any(ord(character) <= 32 for character in value):
        raise ValueError("invalid cache TLS origin")
    parsed = urlsplit(value)
    host = parsed.hostname
    if parsed.scheme != "https" or not host or parsed.username is not None or parsed.password is not None or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("invalid cache TLS origin")
    port = parsed.port if parsed.port is not None else 443
    if not 1 <= port <= 65535:
        raise ValueError("invalid cache TLS port")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        if len(host) > 253 or all(character in "0123456789." for character in host) or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in host.split(".")):
            raise ValueError("invalid cache DNS identity")
        address = None
    # The current cache client accepts IPv4 and DNS endpoints, not IPv6 URLs.
    if address is not None and address.version != 4:
        raise ValueError("unsupported cache IP origin")
    host = str(address) if address is not None else host.lower()
    return host, port, f"https://{host}:{port}"


def protected_path(value, *, missing=False):
    if not isinstance(value, str) or len(value) > 4096 or any(ord(character) < 32 for character in value):
        raise ValueError("invalid cache TLS path")
    path = Path(value)
    if not path.is_absolute() or str(path) != value or ".." in path.parts or TRUST_ROOT not in path.parents:
        raise ValueError("cache TLS paths must be canonical and absolute")
    chain = [path.parent, *path.parent.parents]
    chain = chain[:chain.index(TRUST_ROOT) + 1]
    for directory in reversed(chain):
        metadata = directory.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != TRUST_OWNER or metadata.st_mode & 0o022:
            raise ValueError("cache TLS parent chain must be root controlled")
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if missing:
            return path
        raise
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != TRUST_OWNER or metadata.st_mode & 0o022 or metadata.st_nlink != 1:
        raise ValueError("cache TLS inputs must be protected regular files")
    return path


def identity(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_uid, metadata.st_nlink, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)


def read_protected(value, limit):
    path = protected_path(value)
    initial = path.lstat()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        opened = os.fstat(source.fileno())
        if identity(initial) != identity(opened) or opened.st_size > limit:
            raise ValueError("cache TLS input changed or exceeds its bound")
        contents = source.read(limit + 1)
        if len(contents) > limit or identity(opened) != identity(os.fstat(source.fileno())) or identity(opened) != identity(path.lstat()):
            raise ValueError("cache TLS input changed or exceeds its bound")
    return contents


def digest(contents):
    return "sha256:" + hashlib.sha256(contents).hexdigest()


def certificates(pem):
    pattern = rb"-----BEGIN CERTIFICATE-----[\r\n]+([A-Za-z0-9+/=\r\n]+)-----END CERTIFICATE-----"
    matches = list(re.finditer(pattern, pem))
    if not 1 <= len(matches) <= 16 or re.sub(pattern, b"", pem).strip():
        raise ValueError("cache TLS PEM must contain certificates only")
    values = []
    for match in matches:
        der = base64.b64decode(re.sub(rb"[\r\n]", b"", match[1]), validate=True)
        if not der or len(der) > CERTIFICATE_LIMIT:
            raise ValueError("cache certificate exceeds its bound")
        values.append(der)
    return values


def nodes(data):
    """Read one bounded level of DER TLVs, without recursive ASN.1 decoding."""
    result, offset = [], 0
    while offset < len(data):
        start = offset
        if len(result) >= 128 or offset + 2 > len(data) or data[offset] & 31 == 31:
            raise ValueError("unsupported certificate DER")
        tag, length = data[offset], data[offset + 1]
        offset += 2
        if length & 128:
            width = length & 127
            if not 1 <= width <= 3 or offset + width > len(data) or data[offset] == 0:
                raise ValueError("invalid certificate DER length")
            length = int.from_bytes(data[offset:offset + width], "big")
            if length < 128:
                raise ValueError("noncanonical certificate DER length")
            offset += width
        end = offset + length
        if end > len(data):
            raise ValueError("truncated certificate DER")
        result.append((tag, data[offset:end], data[start:end]))
        offset = end
    return result


def sequence(data):
    values = nodes(data)
    if len(values) != 1 or values[0][0] != 0x30:
        raise ValueError("expected one certificate DER sequence")
    return nodes(values[0][1])


def certificate_time(node):
    tag, value, _ = node
    if tag == 0x17 and re.fullmatch(rb"[0-9]{12}Z", value):
        year = int(value[:2])
        value = (b"19" if year >= 50 else b"20") + value
    elif tag != 0x18 or not re.fullmatch(rb"[0-9]{14}Z", value):
        raise ValueError("unsupported certificate validity time")
    return datetime.strptime(value.decode("ascii"), "%Y%m%d%H%M%SZ").replace(tzinfo=timezone.utc).timestamp()


def metadata(der):
    # RFC5280 sections4.1/4.2 define the exact fields extracted here. OpenSSL
    # remains responsible for signatures, path constraints and critical usage.
    # https://www.rfc-editor.org/rfc/rfc5280.html
    certificate = sequence(der)
    if [node[0] for node in certificate] != [0x30, 0x30, 0x03]:
        raise ValueError("invalid certificate structure")
    fields = nodes(certificate[0][1])
    if not fields or fields[0][0] != 0xA0 or fields[0][1] != b"\x02\x01\x02":
        raise ValueError("cache certificates must be X.509v3")
    fields = fields[1:]
    if len(fields) < 7 or [node[0] for node in fields[:6]] != [0x02, 0x30, 0x30, 0x30, 0x30, 0x30] or [node[0] for node in fields[6:]] not in ([0xA3], [0x81, 0xA3], [0x82, 0xA3], [0x81, 0x82, 0xA3]):
        raise ValueError("invalid certificate fields")
    validity = nodes(fields[3][1])
    if len(validity) != 2:
        raise ValueError("invalid certificate validity")
    extensions = {}
    for extension in sequence(fields[-1][1]):
        if extension[0] != 0x30:
            raise ValueError("invalid certificate extension")
        parts = nodes(extension[1])
        if len(parts) == 3 and parts[1][0] == 0x01 and parts[1][1] in (b"\x00", b"\xff"):
            parts = [parts[0], parts[2]]
        if len(parts) != 2 or [part[0] for part in parts] != [0x06, 0x04] or parts[0][1] in extensions:
            raise ValueError("invalid or duplicated certificate extension")
        extensions[parts[0][1]] = parts[1][1]
    constraints = sequence(extensions.get(b"\x55\x1d\x13", b""))
    if constraints and (constraints[0][0] != 0x01 or constraints[0][1] not in (b"\x00", b"\xff")):
        raise ValueError("invalid certificate basic constraints")
    is_ca = bool(constraints and constraints[0][1] == b"\xff")
    if not is_ca and constraints not in ([], [(0x01, b"\x00", b"\x01\x01\x00")]):
        raise ValueError("invalid nonCA constraints")
    usage = nodes(extensions.get(b"\x55\x1d\x0f", b""))
    if len(usage) != 1 or usage[0][0] != 0x03 or not 2 <= len(usage[0][1]) <= 3 or usage[0][1][0] > 7 or usage[0][1][-1] & ((1 << usage[0][1][0]) - 1):
        raise ValueError("cache certificates require valid key usage")
    return {"ca": is_ca, "keyUsage": usage[0][1][1:], "extensions": extensions, "notBefore": certificate_time(validity[0]), "notAfter": certificate_time(validity[1]), "spkiSha256": digest(fields[5][2])}


def validate_leaf(der, host, now):
    value = metadata(der)
    if value["ca"] or not value["keyUsage"][0] & 0x80 or value["keyUsage"][0] & 0x06:
        raise ValueError("cache leaf must be nonCA with server signing usage")
    purposes = sequence(value["extensions"].get(b"\x55\x1d\x25", b""))
    if not purposes or any(item[0] != 0x06 for item in purposes) or b"\x2b\x06\x01\x05\x05\x07\x03\x01" not in [item[1] for item in purposes]:
        raise ValueError("cache leaf requires explicit serverAuth")
    alternatives = sequence(value["extensions"].get(b"\x55\x1d\x11", b""))
    try:
        expected = ipaddress.ip_address(host).packed
        tag = 0x87
    except ValueError:
        expected, tag = host.lower().encode("ascii"), 0x82
    matched = False
    for alternative in alternatives:
        kind, name, _ = alternative
        if kind == 0x87 and len(name) not in (4, 16):
            raise ValueError("invalid certificate IP SAN")
        if kind == 0x82:
            name.decode("ascii")
            name = name.lower()
        matched = matched or (kind == tag and name == expected)
    # RFC9525 sections6.3/6.4: use SAN identities, never CN fallback. This
    # reviewed pin policy requires exact DNS names, without wildcard expansion.
    # https://www.rfc-editor.org/rfc/rfc9525.html
    if not matched:
        raise ValueError("cache leaf SAN does not match its exact origin")
    if value["notBefore"] > now or value["notAfter"] <= now + VALIDITY_MARGIN_SECONDS:
        raise ValueError("cache leaf validity does not cover the job lifetime")
    return value


def run_openssl(arguments, deadline, directory):
    child = subprocess.Popen([OPENSSL, *arguments], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "OPENSSL_CONF": "/dev/null", "SSL_CERT_DIR": str(directory)})
    buffers = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            for pipe in (child.stdout, child.stderr):
                selector.register(pipe, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("cache certificate verification exceeded its time bound")
                for key, _ in selector.select(remaining):
                    block = os.read(key.fileobj.fileno(), 16384)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    buffers.extend(block)
                    if len(buffers) > 65536:
                        raise ValueError("cache certificate verification exceeded its output bound")
        if child.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            raise ValueError("cache certificate chain verification failed")
    except subprocess.TimeoutExpired:
        raise ValueError("cache certificate verification exceeded its time bound") from None
    finally:
        if child.returncode is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
        child.stdout.close()
        child.stderr.close()


def verify_material(endpoint, leaf_pem, issuer_pem):
    host, _, canonical = origin(endpoint)
    leaves = certificates(leaf_pem)
    if len(leaves) != 1:
        raise ValueError("Bazel trust must contain exactly one server leaf")
    now = int(time.time())
    leaf = validate_leaf(leaves[0], host, now)
    issuers = certificates(issuer_pem)
    if len(set(issuers)) != len(issuers):
        raise ValueError("duplicate issuer certificates")
    for der in issuers:
        issuer = metadata(der)
        if der == leaves[0] or not issuer["ca"] or not issuer["keyUsage"][0] & 0x04:
            raise ValueError("issuer trust bundle must contain CA certificates only")
    deadline = time.monotonic() + VALIDATION_TIMEOUT_SECONDS
    with tempfile.TemporaryDirectory(prefix="nuxie-cache-tls-") as temporary:
        directory = Path(temporary)
        leaf_file, issuer_file = directory / "leaf.pem", directory / "issuer.pem"
        leaf_file.write_bytes(leaf_pem)
        issuer_file.write_bytes(issuer_pem)
        empty = directory / "empty-ca-directory"
        empty.mkdir()
        # LibreSSL3.3.6 supports these options; its CLI lacks verify_ip and
        # verify_hostname. Independent SAN checks above supply that boundary.
        # https://man.openbsd.org/openssl
        for verification_time in (now, now + VALIDITY_MARGIN_SECONDS):
            run_openssl(["verify", "-CAfile", str(issuer_file), "-CApath", str(empty), "-purpose", "sslserver", "-x509_strict", "-attime", str(verification_time), str(leaf_file)], deadline, empty)
    return canonical, digest(leaves[0]), leaf["spkiSha256"]


def unique_fields(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("duplicate TLS pin field")
        result[name] = value
    return result


def material(endpoint, leaf_path, issuer_path):
    if leaf_path == issuer_path:
        raise ValueError("issuer CA bundle must be separate from the server leaf")
    leaf, issuer = read_protected(leaf_path, PEM_LIMIT), read_protected(issuer_path, PEM_LIMIT)
    canonical, der_hash, spki_hash = verify_material(endpoint, leaf, issuer)
    if leaf != read_protected(leaf_path, PEM_LIMIT) or issuer != read_protected(issuer_path, PEM_LIMIT):
        raise ValueError("cache TLS certificates changed during verification")
    return {"version": 1, "endpoint": canonical, "leaf": {"path": leaf_path, "pemSha256": digest(leaf), "derSha256": der_hash, "spkiSha256": spki_hash}, "issuerCa": {"path": issuer_path, "pemSha256": digest(issuer)}}


def validate(receipt_path, endpoint, leaf_path):
    raw = read_protected(receipt_path, 16384)
    receipt = json.loads(raw, object_pairs_hook=unique_fields)
    if not isinstance(receipt, dict) or set(receipt) != {"version", "endpoint", "leaf", "issuerCa"} or type(receipt["version"]) is not int or receipt["version"] != 1 or not isinstance(receipt["leaf"], dict) or set(receipt["leaf"]) != {"path", "pemSha256", "derSha256", "spkiSha256"} or not isinstance(receipt["issuerCa"], dict) or set(receipt["issuerCa"]) != {"path", "pemSha256"}:
        raise ValueError("invalid cache TLS pin receipt")
    if receipt["endpoint"] != origin(endpoint)[2] or receipt["leaf"]["path"] != leaf_path:
        raise ValueError("cache TLS pin must bind the exact origin and leaf path")
    actual = material(endpoint, leaf_path, receipt["issuerCa"]["path"])
    if receipt != actual or read_protected(receipt_path, 16384) != raw:
        raise ValueError("cache TLS pin does not match its protected public inputs")
    return leaf_path


def create(endpoint, leaf_path, issuer_path, output):
    path = protected_path(output, missing=True)
    if path.exists():
        raise ValueError("TLS pin output must not already exist")
    receipt = material(endpoint, leaf_path, issuer_path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(descriptor, "w") as target:
            os.fchmod(target.fileno(), 0o644)
            json.dump(receipt, target, sort_keys=True)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
    except BaseException:
        path.unlink()
        raise
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("create",))
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--leaf", required=True, help="approved public single-leaf PEM")
    parser.add_argument("--issuer-ca", required=True, help="approved public CA-only bundle")
    parser.add_argument("--output", required=True, help="new root-controlled public receipt path")
    arguments = parser.parse_args()
    try:
        create(arguments.endpoint, arguments.leaf, arguments.issuer_ca, arguments.output)
    except (ValueError, OSError, TypeError, AttributeError):
        print("Cache TLS pin creation failed; review protected public certificates and origin", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
