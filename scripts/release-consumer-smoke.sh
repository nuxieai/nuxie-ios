#!/usr/bin/env bash

# Resolve the SDK the way an app does: a fresh temporary SwiftPM package that
# depends on one URL at one version and uses the Nuxie product. This is
# resolution only (the SDK is never built with `swift build` on macOS), but it
# proves that SwiftPM lists the tag as a version, that the manifest loads for a
# consumer, and that the pinned runtime binary downloads and matches its
# checksum. SwiftPM caches, configuration, and fingerprints live in the
# temporary directory, so a temporary tag never reaches the shared stores.

set -euo pipefail

usage() {
    echo "usage: $0 --url URL --version X.Y.Z (--exact | --from) [--revision SHA]" >&2
    exit 64
}

url=""
version=""
rule=""
revision=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url) [[ $# -ge 2 ]] || usage; url="$2"; shift 2 ;;
        --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
        --revision) [[ $# -ge 2 ]] || usage; revision="$2"; shift 2 ;;
        --exact) rule="exact"; shift ;;
        --from) rule="from"; shift ;;
        *) usage ;;
    esac
done

if [[ -z "${url}" || -z "${rule}" ]]; then
    usage
fi
if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "consumer-smoke: version must be X.Y.Z, got '${version}'" >&2
    exit 64
fi
if [[ -n "${revision}" && ! "${revision}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "consumer-smoke: revision must be a full commit hash, got '${revision}'" >&2
    exit 64
fi
if [[ "${url}" == *'"'* || "${url}" == *\\* ]]; then
    echo "consumer-smoke: URL must not contain quotes or backslashes" >&2
    exit 64
fi

# SwiftPM derives the package identity from the last URL path component.
identity="$(basename "${url%/}")"
identity="${identity%.git}"
identity="$(printf '%s' "${identity}" | tr '[:upper:]' '[:lower:]')"

temporary="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-release-consumer.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT
consumer="${temporary}/consumer"
mkdir -p "${consumer}/Sources/NuxieReleaseConsumer"
cat >"${consumer}/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NuxieReleaseConsumer",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [
        .package(url: "${url}", ${rule}: "${version}"),
    ],
    targets: [
        .target(
            name: "NuxieReleaseConsumer",
            dependencies: [.product(name: "Nuxie", package: "${identity}")]
        ),
    ]
)
EOF
printf '%s\n' 'import Nuxie' >"${consumer}/Sources/NuxieReleaseConsumer/Consumer.swift"

log="${temporary}/resolve.log"
if ! env -u NUXIE_RUNTIME_USE_LOCAL swift package \
    --package-path "${consumer}" \
    --scratch-path "${temporary}/scratch" \
    --cache-path "${temporary}/cache" \
    --config-path "${temporary}/config" \
    --security-path "${temporary}/security" \
    resolve >"${log}" 2>&1; then
    echo "consumer-smoke: SwiftPM could not resolve ${url} with ${rule}: \"${version}\"" >&2
    grep -v 'Downloading ' "${log}" | tail -n 40 >&2
    exit 1
fi

resolved_revision="$(python3 - "${consumer}/Package.resolved" "${identity}" "${version}" "${revision}" "${rule}" <<'PY'
import json
import sys

path, identity, version, revision, rule = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as resolved_file:
        resolved = json.load(resolved_file)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"consumer-smoke: cannot read Package.resolved: {error}")
pins = [pin for pin in resolved.get("pins", []) if pin.get("identity") == identity]
if len(pins) != 1:
    raise SystemExit(f"consumer-smoke: Package.resolved has no single {identity} pin")
state = pins[0].get("state") or {}
if state.get("version") != version:
    hint = ""
    if rule == "from":
        hint = " (a newer release in the same major version also satisfies from:)"
    raise SystemExit(
        f"consumer-smoke: resolved {identity} {state.get('version')!r}, "
        f"expected {version}{hint}"
    )
if revision and state.get("revision") != revision:
    raise SystemExit(
        f"consumer-smoke: {identity} {version} resolved to {state.get('revision')}, "
        f"expected {revision}"
    )
print(state.get("revision"))
PY
)"

if [[ -z "$(find "${temporary}/scratch/artifacts" -type d -name NuxieRuntime.xcframework -print -quit 2>/dev/null)" ]]; then
    echo "consumer-smoke: SwiftPM resolved ${identity} but did not fetch NuxieRuntime.xcframework" >&2
    exit 1
fi

echo "Consumer resolved ${identity} ${version} at ${resolved_revision} (${rule}: \"${version}\") with its runtime binary"
