#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "check-event-catalog: jq is required" >&2
  exit 1
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "check-event-catalog: rg is required" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/fixtures/events/catalog.json"
status=0

jq empty "$catalog"

while IFS=$'\t' read -r event_name reason; do
  echo "Catalog event $event_name is invalid: $reason" >&2
  status=1
done < <(
  jq -r '
    def strings: type == "string" or
      (type == "array" and length > 0 and all(.[]; type == "string"));
    def bools: type == "boolean" or
      (type == "array" and length > 0 and all(.[]; type == "boolean"));
    to_entries[]
    | .key as $event | .value as $row
    | ($row.lane | if type == "array" then length else 1 end) as $count
    | if ($event | startswith("$") | not) then [$event, "name must start with $"] | @tsv
      elif $row.status != "active" then [$event, "only active events belong in the current catalog"] | @tsv
      elif (($row.constant | type) != "string") then [$event, "constant is required"] | @tsv
      elif (($row.emitters | type) != "array" or ($row.emitters | length) == 0) then [$event, "at least one emitter is required"] | @tsv
      elif (($row.properties | type) != "object") then [$event, "properties must be an object"] | @tsv
      elif (($row.lane | strings) and ($row.beforeSend | strings)
        and ($row.endpoint | strings) and ($row.persists | bools) and ($row.wire | bools)
        and (($row.beforeSend | type) != "array" or ($row.beforeSend | length) == $count)
        and (($row.endpoint | type) != "array" or ($row.endpoint | length) == $count)
        and (($row.persists | type) != "array" or ($row.persists | length) == $count)
        and (($row.wire | type) != "array" or ($row.wire | length) == $count)) | not
        then [$event, "semantic arrays must align with lane"] | @tsv
      else empty end
  ' "$catalog"
)

while IFS=$'\t' read -r event_name constant; do
  owner="${constant%%.*}"
  symbol="${constant#*.}"
  case "$owner" in
    SystemEventNames) source_file="$repo_root/Sources/Nuxie/Events/SystemEventNames.swift" ;;
    JourneyEvents) source_file="$repo_root/Sources/Nuxie/Journey/Events/JourneyEvents.swift" ;;
    *)
      echo "Catalog event $event_name has unsupported constant owner $owner" >&2
      status=1
      continue
      ;;
  esac
  if ! rg -Fq -- "static let $symbol = \"$event_name\"" "$source_file"; then
    echo "Catalog constant $constant does not declare $event_name" >&2
    status=1
  fi
done < <(jq -r 'to_entries[] | [.key, .value.constant] | @tsv' "$catalog")

while IFS=$'\t' read -r owner source_file; do
  while IFS=$'\t' read -r symbol event_name; do
    constant="$owner.$symbol"
    catalog_constant="$(jq -r --arg event "$event_name" '.[$event].constant // empty' "$catalog")"
    if [[ "$catalog_constant" != "$constant" ]]; then
      echo "Source declaration $constant = $event_name is missing or mismatched in the catalog" >&2
      status=1
    fi
  done < <(sed -En 's/^[[:space:]]*static let ([A-Za-z0-9_]+) = "(\$[^"]+)".*/\1\t\2/p' "$repo_root/$source_file")
done <<'SOURCES'
SystemEventNames	Sources/Nuxie/Events/SystemEventNames.swift
JourneyEvents	Sources/Nuxie/Journey/Events/JourneyEvents.swift
SOURCES

while IFS= read -r emitter; do
  if [[ ! -f "$repo_root/$emitter" ]]; then
    echo "Catalog emitter does not exist: $emitter" >&2
    status=1
  fi
done < <(jq -r '.[].emitters[]' "$catalog" | sort -u)

forbidden='DeviceLeg|device[- ]leg|LegacyJourney|JourneyRunner|trackWithResponse|trackForTrigger|commitServerFacts|\$journey_(claimed|converted|effect_completed|effect_requested|enrolled|exited|handoff|parked|started|superseded|transition)|\$experiment_exposure_(error|fallback)|\$event_sent'
for path in fixtures/events/catalog.json docs/events-catalog.md docs/forward-nuxie-activity.md docs/sdk-events.md; do
  [[ -f "$repo_root/$path" ]] || continue
  if rg -ni -- "$forbidden" "$repo_root/$path"; then
    echo "Retired Journey contract remains in $path" >&2
    status=1
  fi
done

exit "$status"
