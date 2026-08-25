#!/usr/bin/env bash
set -euo pipefail

# ripgrep is not part of the documented contributor setup (make install-deps
# provisions XcodeGen only), so fall back to grep when rg is absent. The shim
# covers exactly the call shapes this script uses: `rg -Fq -- PATTERN PATH...`
# and `rg -n --no-heading PATTERN PATH --glob '*.swift'`.
if ! command -v jq >/dev/null 2>&1; then
  echo "check-event-catalog: jq is required (run 'make install-deps' or 'brew install jq')" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  rg() {
    local arg fixed=0 quiet=0 lines=0 skip_next=0
    local -a positional=()
    for arg in "$@"; do
      if [[ "$skip_next" -eq 1 ]]; then
        skip_next=0
        continue
      fi
      case "$arg" in
        -Fq) fixed=1; quiet=1 ;;
        -n) lines=1 ;;
        --no-heading) ;;
        --glob) skip_next=1 ;;
        --) ;;
        *) positional+=("$arg") ;;
      esac
    done
    local -a grep_cmd=(grep -r --include='*.swift')
    if [[ "$fixed" -eq 1 ]]; then grep_cmd+=(-F); else grep_cmd+=(-E); fi
    if [[ "$quiet" -eq 1 ]]; then grep_cmd+=(-q); fi
    if [[ "$lines" -eq 1 ]]; then grep_cmd+=(-n); fi
    "${grep_cmd[@]}" -- "${positional[@]}"
  }
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/fixtures/events/catalog.json"
status=0
emitter_window_radius=64

# Review-mandated production emission calls. The generic capture/emit forms
# include named SDK wrappers such as captureOnly and emitSystemEvent.
emission_call_pattern='eventSink[.]emit[[:space:]]*[(]|eventLog[.]track(WithoutRouting)?[[:space:]]*[(]'
emission_call_pattern+='|trackForTrigger[[:space:]]*[(]|trackWithResponse[[:space:]]*[(]'
emission_call_pattern+='|trackScopedEvent[[:space:]]*[(]|captureStableSystemEvent[[:space:]]*[(]'
emission_call_pattern+='|eventSink[.]capture[[:space:]]*[(]|[[:alnum:]_.]*captureOnly[[:space:]]*[(]'
emission_call_pattern+='|[[:alnum:]_.]*emitSystemEvent[[:space:]]*[(]'
emission_call_pattern+='|[[:alnum:]_.]*capture[[:alnum:]_]*[[:space:]]*[(]'
emission_call_pattern+='|[[:alnum:]_.]*emit[[:alnum:]_]*[[:space:]]*[(]'
emission_call_pattern+='|storePreparedEventInHistory[[:space:]]*[(]'
emission_call_pattern+='|ExperienceRendererEvent[[:space:]]*[(]|ScreenEmission[[:space:]]*[(]'
emission_call_pattern+='|didEmitEvent'

# Reverse coverage deliberately starts from production emission calls, rather
# than constant references. This makes bare literals and indirect names visible.
reverse_emission_call_pattern='[[:alnum:]_.]*[Ee]ventSink[.]emit[[:space:]]*[(]|eventLog[.]track(WithoutRouting)?[[:space:]]*[(]'
reverse_emission_call_pattern+='|trackForTrigger[[:space:]]*[(]|trackWithResponse[[:space:]]*[(]'
reverse_emission_call_pattern+='|trackScopedEvent[[:space:]]*[(]|captureStableSystemEvent[[:space:]]*[(]'
reverse_emission_call_pattern+='|eventSink[.]capture[[:space:]]*[(]|[[:alnum:]_.]*captureOnly[[:space:]]*[(]'
reverse_emission_call_pattern+='|[[:alnum:]_.]*emitSystemEvent[[:space:]]*[(]'
reverse_emission_call_pattern+='|[[:alnum:]_.]*captureOwnedJourneySystemEvent[[:space:]]*[(]'
reverse_emission_call_pattern+='|[[:alnum:]_.]*captureSystemEvent(Only)?[[:space:]]*[(]'
reverse_emission_call_pattern+='|storePreparedEventInHistory[[:space:]]*[(]'
reverse_emission_call_pattern+='|ExperienceRendererEvent[[:space:]]*[(]|ScreenEmission[[:space:]]*[(]'
reverse_emission_call_pattern+='|emitEvent[[:space:]]*[(]'
reverse_emission_call_pattern+='|[[:alnum:]_.]*trackEvent[[:space:]]*[(]'
server_fact_builder_pattern='name:[[:space:]]*fact[.]event[.]rawValue'

# These exact sites are intentionally not ordinary analytics emission calls:
# three are server facts committed locally and one is the direct feature API
# call. Keep this allowlist short and explicit.
is_allowlisted_catalog_site() {
  case "$1|$2" in
    '$journey_converted|Sources/Nuxie/Events/EventLog.swift:1869' \
      | '$journey_effect_completed|Sources/Nuxie/Events/EventLog.swift:1869' \
      | '$journey_superseded|Sources/Nuxie/Events/EventLog.swift:1869' \
      | '$feature_used|Sources/Nuxie/NuxieSDK.swift:1123')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Indirect sites with a finite event set are mapped independently of the
# catalog, so removing any one expected emitter entry fails closed.
catalog_event_emitters_for_indirect_emission_site() {
  case "$1" in
    'Sources/Nuxie/Journey/JourneyService.swift:2382')
      # The permission mapper stages exactly these six cataloged result names.
      printf '%s\t%s\n' \
        '$notifications_denied' "$1" \
        '$notifications_enabled' "$1" \
        '$permission_denied' "$1" \
        '$permission_granted' "$1" \
        '$tracking_authorized' "$1" \
        '$tracking_denied' "$1"
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:883')
      # The generic sink carries these six variable-selected permission results; other callers pass cataloged constants.
      printf '%s\t%s\n' \
        '$notifications_denied' "$1" \
        '$notifications_enabled' "$1" \
        '$permission_denied' "$1" \
        '$permission_granted' "$1" \
        '$tracking_authorized' "$1" \
        '$tracking_denied' "$1"
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:1633')
      # Notification dispatch forwards one of two names to emitSystemEvent; the sink seam is cataloged at line 883.
      printf '%s\t%s\n' \
        '$notifications_denied' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:883' \
        '$notifications_enabled' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:883'
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:1652')
      # Tracking dispatch forwards one of two names to emitSystemEvent; the sink seam is cataloged at line 883.
      printf '%s\t%s\n' \
        '$tracking_authorized' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:883' \
        '$tracking_denied' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:883'
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:1671')
      # Permission dispatch forwards one of two names to emitSystemEvent; the sink seam is cataloged at line 883.
      printf '%s\t%s\n' \
        '$permission_denied' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:883' \
        '$permission_granted' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:883'
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:2439')
      # The scoped milestone stage is constructed from $journey_milestone.
      printf '%s\t%s\n' '$journey_milestone' "$1"
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:2919')
      # The indirect scoped call forwards the fixed denial staged and cataloged at this site.
      printf '%s\t%s\n' \
        '$permission_denied' 'Sources/Nuxie/Journey/JourneyService.swift:2919'
      ;;
    'Sources/Nuxie/Events/EventLog.swift:1891')
      # JourneyDownFact.Event has exactly these three cataloged raw values.
      printf '%s\t%s\n' \
        '$journey_converted' "$1" \
        '$journey_effect_completed' "$1" \
        '$journey_superseded' "$1"
      ;;
    'Sources/Nuxie/Experiences/Runtime/ScreenEmissionDispatcher.swift:432')
      # The materializer selects these two reserved response names; authored event names cannot start with `$`.
      printf '%s\t%s\n' \
        '$response_set' 'Sources/Nuxie/Experiences/Runtime/ScreenEmissionDispatcher.swift:426' \
        '$response_unset' 'Sources/Nuxie/Experiences/Runtime/ScreenEmissionDispatcher.swift:429'
      ;;
    *)
      return 1
      ;;
  esac
}

# Generic forwarding layers and authored/custom-event paths cannot resolve to
# one finite catalog set at the call. Each exact exception documents where any
# reserved SDK-authored names are checked instead.
is_allowlisted_indirect_emission_site() {
  case "$1" in
    'Sources/Nuxie/Events/EventLog.swift:1045' \
      | 'Sources/Nuxie/Events/EventLog.swift:1223' \
      | 'Sources/Nuxie/Events/EventLog.swift:1692' \
      | 'Sources/Nuxie/Events/EventLog.swift:2931')
      # Delivery-path apiClient.trackEvent calls transport an already-built
      # NuxieEvent; the event name originated in a capture lane whose call
      # site is checked above, so these sites are transport, not emission.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:246')
      # Protocol convenience forwards names; concrete SDK callers are checked at their call sites.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:265')
      # The ownership convenience forwards names; its concrete producer is checked at the owned capture call site.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:520' \
      | 'Sources/Nuxie/Events/EventLog.swift:534' \
      | 'Sources/Nuxie/Events/EventLog.swift:546' \
      | 'Sources/Nuxie/Events/EventLog.swift:948' \
      | 'Sources/Nuxie/Events/EventLog.swift:960')
      # EventLog overloads forward names; concrete SDK callers are checked at their call sites.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:1300' \
      | 'Sources/Nuxie/Events/EventLog.swift:1321')
      # Stable-capture wrappers forward names; their concrete scoped producers are cataloged.
      return 0
      ;;
    'Sources/Nuxie/Events/TriggerService.swift:177')
      # TriggerService forwards public event names; reserved SDK callers are checked upstream.
      return 0
      ;;
    'Sources/Nuxie/Events/TriggerService.swift:40' \
      | 'Sources/Nuxie/Events/TriggerService.swift:123' \
      | 'Sources/Nuxie/Events/TriggerService.swift:155')
      # Capture protocol/service layers forward names; concrete event-sink callers are checked upstream.
      return 0
      ;;
    'Sources/Nuxie/DI/RuntimeProviders.swift:86' \
      | 'Sources/Nuxie/DI/RuntimeProviders.swift:101')
      # Runtime role adapters forward names; concrete event-sink capture and captureOnly calls are checked.
      return 0
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:1347')
      # Renderer-authored names are curated by the screen emission router before this call.
      return 0
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:2495')
      # This history-only write reuses the milestone stage cataloged at line 2433.
      return 0
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:2487')
      # This direct scoped send reuses the milestone stage cataloged at line 2433.
      return 0
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:5048')
      # The scoped helper forwards stages whose finite producers are checked at their call sites.
      return 0
      ;;
    'Sources/Nuxie/Journey/Execution/JourneyRunner.swift:3248')
      # Authored send-event names are user-defined; the $event_sent rider below is cataloged.
      return 0
      ;;
    'Sources/Nuxie/Experiences/ExperienceScreenViewController.swift:796')
      # This constructor forwards names checked at the concrete response emitEvent call sites; other names are authored.
      return 0
      ;;
    'Sources/Nuxie/Experiences/ExperienceScreenViewController.swift:716')
      # Renderer-reported event names are authored; reserved response names use the concrete calls below.
      return 0
      ;;
    'Sources/Nuxie/Experiences/ExperienceScreenViewController.swift:763')
      # Runtime journey and host-command names are variable; reserved response names use the concrete calls above.
      return 0
      ;;
    'Sources/Nuxie/NuxieSDK.swift:1194')
      # Accepted feature usage is durably mirrored through the prepared-event history seam.
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

cd "$repo_root"
jq empty "$catalog"

# The status vocabulary is closed; the status-dependent checks below only
# recognize these four values, so an unknown status must fail rather than
# silently skip them.
while IFS=$'\t' read -r event_name event_status; do
  echo "Catalog event $event_name has unknown status '$event_status' (expected active|renaming|delete|retired)" >&2
  status=1
done < <(
  jq -r '
    to_entries[]
    | select(.value.status as $s | ["active", "renaming", "delete", "retired"] | index($s) | not)
    | [.key, .value.status]
    | @tsv
  ' "$catalog"
)

while IFS=$'\t' read -r event_name event_status; do
  echo "Catalog event $event_name ($event_status) has no production emitter" >&2
  status=1
done < <(
  jq -r '
    to_entries[]
    | select(.value.status != "delete" and .value.status != "retired")
    | select(.value.emitters | length == 0)
    | [.key, .value.status]
    | @tsv
  ' "$catalog"
)

while IFS=$'\t' read -r event_name event_status emitters; do
  echo "Catalog event $event_name ($event_status) is cataloged as having no production emitter but has emitters: $emitters" >&2
  status=1
done < <(
  jq -r '
    to_entries[]
    | select(.value.status == "delete" or .value.status == "retired")
    | select((.value.emitters | type) != "array" or (.value.emitters | length) != 0)
    | [.key, .value.status, (.value.emitters | tojson)]
    | @tsv
  ' "$catalog"
)

while IFS=$'\t' read -r event_name constant event_status emitter; do

  if [[ ! "$emitter" =~ ^(.+\.swift):([0-9]+)$ ]]; then
    echo "Invalid emitter reference for $event_name: $emitter" >&2
    status=1
    continue
  fi

  source_path="${BASH_REMATCH[1]}"
  source_line="${BASH_REMATCH[2]}"
  if [[ ! -f "$source_path" ]]; then
    echo "Missing emitter source for $event_name: $source_path" >&2
    status=1
    continue
  fi

  first_line=$((source_line > emitter_window_radius ? source_line - emitter_window_radius : 1))
  last_line=$((source_line + emitter_window_radius))
  source_window="$(sed -n "${first_line},${last_line}p" "$source_path")"

  if ! grep -Eq "$emission_call_pattern" <<< "$source_window" \
      && ! is_allowlisted_catalog_site "$event_name" "$emitter"; then
    echo "Emission call not found within +/-${emitter_window_radius} lines of $emitter for $event_name" >&2
    status=1
    continue
  fi

  token_found=false
  if [[ -n "$constant" ]]; then
    constant_pattern="${constant//./\\.}"
    if grep -Eq "(^|[^[:alnum:]_])${constant_pattern}([^[:alnum:]_]|$)" <<< "$source_window"; then
      token_found=true
    fi
  elif grep -Fq -- "\"$event_name\"" <<< "$source_window"; then
    token_found=true
  fi

  if [[ "$token_found" != true
      && "$source_path" == "Sources/Nuxie/Events/EventLog.swift"
      && "$constant" == JourneyEvents.journey* ]]; then
    # Server facts are emitted by a generic fact.event.rawValue path. At that
    # seam the exact event is selected by a JourneyDownFact case rather than a
    # JourneyEvents constant, so bind the catalog constant to that exact case.
    constant_name="${constant##*.}"
    fact_case="${constant_name#journey}"
    fact_case="$(tr '[:upper:]' '[:lower:]' <<< "${fact_case:0:1}")${fact_case:1}"
    fact_declaration="case $fact_case = \"$event_name\""
    if grep -Fq -- "name: fact.event.rawValue" <<< "$source_window" \
        && rg -Fq -- "$fact_declaration" Sources/Nuxie/Network/Models/ResponseModels.swift; then
      token_found=true
    fi
  fi

  if [[ "$token_found" != true ]] \
      && [[ "$constant" == SystemEventNames.notifications* \
          || "$constant" == SystemEventNames.permission* \
          || "$constant" == SystemEventNames.tracking* ]]; then
    # Permission names are selected in the controller, then cross either the
    # generic scoped track call or the generic SystemEventSink emission call.
    if rg -Fq -- "eventName = $constant" \
        Sources/Nuxie/Experiences/ExperienceViewController.swift; then
      token_found=true
    fi
  fi

  if [[ "$token_found" != true
      && "$constant" == "JourneyEvents.journeyMilestone"
      && "$emitter" == "Sources/Nuxie/Journey/JourneyService.swift:2439" ]] \
      && rg -Fq -- 'name: JourneyEvents.journeyMilestone' \
        Sources/Nuxie/Journey/JourneyService.swift; then
    # The scoped path stages the exact milestone name before the generic
    # trackScopedEvent call validated above.
    token_found=true
  fi

  if [[ "$token_found" != true ]]; then
    expected_token="${constant:-$event_name}"
    echo "Emitter token '$expected_token' not found within +/-${emitter_window_radius} lines of $emitter for $event_name" >&2
    status=1
  fi
done < <(
  jq -r '
    to_entries[]
    | .key as $event
    | (.value.constant // "") as $constant
    | .value.status as $status
    | .value.emitters[]
    | [$event, $constant, $status, .]
    | @tsv
  ' "$catalog"
)

# Reverse coverage: enumerate calls first, then classify their event-name
# argument as a catalog constant, a reserved literal, or an indirect producer.
while IFS=: read -r source_path source_line source_text; do
  call_site="$source_path:$source_line"
  argument_site="$call_site"

  if grep -Eq "$server_fact_builder_pattern" <<< "$source_text"; then
    event_argument='fact.event.rawValue'
  else
    if [[ ! "$source_text" =~ $reverse_emission_call_pattern ]]; then
      continue
    fi
    matched_call="${BASH_REMATCH[0]}"
    call_prefix="${source_text%%"$matched_call"*}"
    if [[ "$call_prefix" =~ (^|[[:space:]])func[[:space:]]*$ ]]; then
      continue
    fi

    event_argument="${source_text#*"$matched_call"}"
    event_argument="${event_argument#"${event_argument%%[![:space:]]*}"}"
    if [[ -z "$event_argument" || "$event_argument" == //* ]]; then
      event_argument=''
      for ((argument_line = source_line + 1; argument_line <= source_line + 8; argument_line++)); do
        candidate="$(sed -n "${argument_line}p" "$source_path")"
        candidate="${candidate#"${candidate%%[![:space:]]*}"}"
        if [[ -n "$candidate" && "$candidate" != //* ]]; then
          event_argument="$candidate"
          argument_site="$source_path:$argument_line"
          break
        fi
      done
    fi
    if [[ "$matched_call" =~ ^(ExperienceRendererEvent|ScreenEmission|emitEvent) ]] \
        && [[ "$event_argument" =~ ^name:[[:space:]]*(.*)$ ]]; then
      event_argument="${BASH_REMATCH[1]}"
    fi
    if [[ "$matched_call" =~ trackEvent ]] \
        && [[ "$event_argument" =~ ^event:[[:space:]]*(.*)$ ]]; then
      event_argument="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -z "$event_argument" ]]; then
    echo "Source emission $call_site has no readable event-name argument" >&2
    status=1
    continue
  fi

  event_name=''
  constant=''
  if [[ "$event_argument" =~ ^((SystemEventNames|JourneyEvents)[.][[:alnum:]_]+)[[:space:]]*(,|\)) ]]; then
    constant="${BASH_REMATCH[1]}"
    event_name="$(jq -r --arg constant "$constant" '
      [to_entries[] | select(.value.constant == $constant) | .key]
      | if length == 1 then .[0] else empty end
    ' "$catalog")"
    if [[ -z "$event_name" ]]; then
      echo "Source emission $argument_site uses catalog constant $constant, but it does not resolve to exactly one catalog key" >&2
      status=1
      continue
    fi
  elif [[ "$event_argument" =~ ^\"(\$[^\"]+)\"[[:space:]]*(,|\)) ]]; then
    event_name="${BASH_REMATCH[1]}"
    if ! jq -e --arg event_name "$event_name" 'has($event_name)' "$catalog" >/dev/null; then
      echo "Source emission $argument_site uses reserved literal $event_name, but that name is missing from the event catalog" >&2
      status=1
      continue
    fi
  else
    if mapped_event_emitters="$(catalog_event_emitters_for_indirect_emission_site "$call_site")"; then
      while IFS=$'\t' read -r mapped_event_name mapped_emitter; do
        if ! jq -e --arg event_name "$mapped_event_name" 'has($event_name)' \
            "$catalog" >/dev/null; then
          echo "Indirect source emission $call_site maps to $mapped_event_name, but that name is missing from the event catalog" >&2
          status=1
          continue
        fi
        mapped_event_status="$(jq -r --arg event_name "$mapped_event_name" \
          '.[$event_name].status' "$catalog")"
        if [[ "$mapped_event_status" == "delete" || "$mapped_event_status" == "retired" ]]; then
          echo "Indirect source emission $call_site resolves to $mapped_event_name ($mapped_event_status), but the event is cataloged as having no production emitter" >&2
          status=1
          continue
        fi
        if ! jq -e --arg event_name "$mapped_event_name" --arg emitter "$mapped_emitter" '
            any(.[$event_name].emitters[]; . == $emitter)
          ' "$catalog" >/dev/null; then
          echo "Indirect source emission $call_site for $mapped_event_name expects $mapped_emitter in that catalog row's emitters" >&2
          status=1
        fi
      done <<< "$mapped_event_emitters"
    elif ! is_allowlisted_indirect_emission_site "$call_site"; then
      argument_summary="${event_argument%%,*}"
      echo "Indirect source emission $call_site uses '$argument_summary'; add the site to every matching catalog row or document it in is_allowlisted_indirect_emission_site" >&2
      status=1
    fi
    continue
  fi

  event_status="$(jq -r --arg event_name "$event_name" '.[$event_name].status' "$catalog")"
  source_kind="${constant:-$event_name}"
  if [[ "$event_status" == "delete" || "$event_status" == "retired" ]]; then
    echo "Source emission $argument_site for $source_kind resolves to $event_name ($event_status), but the event is cataloged as having no production emitter" >&2
    status=1
  elif [[ "$event_status" == "active" || "$event_status" == "renaming" ]]; then
    if ! jq -e --arg event_name "$event_name" --arg emitter "$argument_site" '
        any(.[$event_name].emitters[]; . == $emitter)
      ' "$catalog" >/dev/null; then
      echo "Source emission $argument_site for $source_kind resolves to $event_name ($event_status) but is missing from that catalog row's emitters" >&2
      status=1
    fi
  fi
done < <(
  rg -n --no-heading \
    "$reverse_emission_call_pattern|$server_fact_builder_pattern" \
    Sources --glob '*.swift' \
    | sort -u
)

while IFS=$'\t' read -r event_name event_status; do
  if [[ "$event_status" == "delete" || "$event_status" == "retired" ]]; then
    continue
  fi
  if ! rg -Fq -- "$event_name" Sources; then
    echo "Catalog event $event_name ($event_status) does not appear under Sources" >&2
    status=1
  fi
done < <(jq -r 'to_entries[] | [.key, .value.status] | @tsv' "$catalog")

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "Event catalog emitters and source coverage are valid"
