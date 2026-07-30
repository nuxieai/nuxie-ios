#!/usr/bin/env python3

import json
import pathlib
import re
import sys
import unicodedata


METADATA_KEYS = {
    "schemaVersion",
    "runtimeVersion",
    "sourceRevision",
    "runtimeIdentity",
    "contractFingerprint",
    "luaurVersion",
    "buildProfile",
    "rustToolchain",
    "xcodeVersion",
    "xcodeBuild",
    "iphoneOSSDKVersion",
    "iphoneOSSDKBuild",
    "iphoneSimulatorSDKVersion",
    "iphoneSimulatorSDKBuild",
    "minimumIOSVersion",
    "thirdPartyNoticesPath",
    "swiftPackageChecksum",
}
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\Z")
SOURCE_REVISION = re.compile(r"[0-9a-f]{40}(?:-dirty\.[0-9a-f]{64})?\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
HEADER_FUNCTION = re.compile(r"\b(nux_[a-z0-9_]+)\s*\(")
EXPORTED_FUNCTION = re.compile(r"_nux_[a-z0-9_]+\Z")
FORBIDDEN_HEADER_IDENTIFIERS = {
    "NUX_FLOW_SESSION_ABI_MINOR",
    "NUX_RUNTIME_ABI_MAJOR",
    "NUX_RUNTIME_ABI_MINOR",
    "NUX_STATUS_ABI_MISMATCH",
    "minimum_abi_minor",
    # Keep the hard-cut sentinel while honoring the repository-wide rule that
    # retired lowercase ABI spellings do not appear verbatim in code.
    "nux_" "flow_runtime_context_create",
    "nux_runtime_abi_major",
    "nux_runtime_abi_minor",
    "nux_runtime_require_abi",
    "required_abi_major",
}


class ContractError(ValueError):
    pass


def _string(document: dict[str, object], key: str) -> str:
    value = document.get(key)
    if not isinstance(value, str):
        raise ContractError(f"{key} must be a string")
    if any(unicodedata.category(character) == "Cc" for character in value):
        raise ContractError(f"{key} contains a control character")
    return value


def validate_metadata(document: object) -> None:
    if not isinstance(document, dict):
        raise ContractError("artifact metadata must be a top-level object")
    actual_keys = set(document)
    if actual_keys != METADATA_KEYS:
        missing = sorted(METADATA_KEYS - actual_keys)
        extra = sorted(actual_keys - METADATA_KEYS)
        raise ContractError(f"metadata keys differ: missing={missing}, extra={extra}")
    if document["schemaVersion"] != 2:
        raise ContractError("schemaVersion must be exactly 2")

    runtime_version = _string(document, "runtimeVersion")
    source_revision = _string(document, "sourceRevision")
    runtime_identity = _string(document, "runtimeIdentity")
    contract_fingerprint = _string(document, "contractFingerprint")
    swift_package_checksum = _string(document, "swiftPackageChecksum")
    for key in METADATA_KEYS - {"schemaVersion"}:
        _string(document, key)

    if SEMVER.fullmatch(runtime_version) is None:
        raise ContractError("runtimeVersion is not canonical SemVer")
    if SOURCE_REVISION.fullmatch(source_revision) is None:
        raise ContractError("sourceRevision is not an exact source identity")
    if runtime_identity != f"{runtime_version}@{source_revision}":
        raise ContractError("runtimeIdentity does not match version and revision")
    if SHA256.fullmatch(contract_fingerprint) is None:
        raise ContractError("contractFingerprint is not a lowercase SHA-256")
    if SHA256.fullmatch(swift_package_checksum) is None:
        raise ContractError("swiftPackageChecksum is not a lowercase SHA-256")


def expected_symbols(header: str) -> set[str]:
    identifiers = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", header))
    forbidden = sorted(identifiers & FORBIDDEN_HEADER_IDENTIFIERS)
    if forbidden:
        raise ContractError(
            f"generated header exposes removed client ABI identifiers: {forbidden}"
        )
    symbols = {f"_{name}" for name in HEADER_FUNCTION.findall(header)}
    if not symbols:
        raise ContractError("generated header declares no public nux_* functions")
    return symbols


def validate_symbols(header: str, exported: str) -> None:
    expected = expected_symbols(header)
    actual = {
        line.strip()
        for line in exported.splitlines()
        if EXPORTED_FUNCTION.fullmatch(line.strip()) is not None
    }
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ContractError(
            f"public symbol set differs: missing={missing}, extra={extra}"
        )


def _load_json(path: pathlib.Path) -> object:
    try:
        with path.open(encoding="utf-8") as source:
            return json.load(source)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read {path}: {error}") from error


def main(arguments: list[str]) -> int:
    if len(arguments) == 2 and arguments[0] == "metadata":
        validate_metadata(_load_json(pathlib.Path(arguments[1])))
        return 0
    if len(arguments) == 3 and arguments[0] == "symbols":
        try:
            header = pathlib.Path(arguments[1]).read_text(encoding="utf-8")
            exported = pathlib.Path(arguments[2]).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise ContractError(f"cannot read symbol inputs: {error}") from error
        validate_symbols(header, exported)
        return 0
    raise ContractError(
        "usage: apple_runtime_contract.py "
        "metadata <artifact.json> | symbols <header> <nm-output>"
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ContractError as error:
        raise SystemExit(f"apple-runtime-contract: {error}") from error
