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
    local arg fixed=0 quiet=0 lines=0 skip_next=0 multiline=0
    local -a positional=()
    for arg in "$@"; do
      if [[ "$skip_next" -eq 1 ]]; then
        skip_next=0
        continue
      fi
      case "$arg" in
        -Fq) fixed=1; quiet=1 ;;
        -Uq) multiline=1; quiet=1 ;;
        -n) lines=1 ;;
        --no-heading) ;;
        --glob) skip_next=1 ;;
        --) ;;
        *) positional+=("$arg") ;;
      esac
    done
    if [[ "$multiline" -eq 1 ]]; then
      # Stock grep has no multiline mode; perl ships with macOS and gives
      # quiet whole-file matching for the checker's -Uq call shapes.
      local pattern="${positional[0]}"
      local file
      for file in "${positional[@]:1}"; do
        if PATTERN="$pattern" perl -0777 -ne 'exit 0 if $_ =~ $ENV{PATTERN}; exit 1' "$file"; then
          return 0
        fi
      done
      return 1
    fi
    local -a grep_cmd=(grep -r --include='*.swift')
    if [[ "$fixed" -eq 1 ]]; then grep_cmd+=(-F); else grep_cmd+=(-E); fi
    if [[ "$quiet" -eq 1 ]]; then grep_cmd+=(-q); fi
    if [[ "$lines" -eq 1 ]]; then grep_cmd+=(-n); fi
    "${grep_cmd[@]}" -- "${positional[@]}"
  }
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/fixtures/events/catalog.json"
catalog_markdown="$repo_root/docs/events-catalog.md"
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
    '$journey_converted|Sources/Nuxie/Events/EventLog.swift:1951' \
      | '$journey_effect_completed|Sources/Nuxie/Events/EventLog.swift:1951' \
      | '$journey_superseded|Sources/Nuxie/Events/EventLog.swift:1951' \
      | '$feature_used|Sources/Nuxie/NuxieSDK.swift:1095')
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
    'Sources/Nuxie/Journey/JourneyService.swift:2510')
      # The permission mapper stages exactly these six cataloged result names.
      printf '%s\t%s\n' \
        '$notifications_denied' "$1" \
        '$notifications_enabled' "$1" \
        '$permission_denied' "$1" \
        '$permission_granted' "$1" \
        '$tracking_authorized' "$1" \
        '$tracking_denied' "$1"
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:886')
      # The generic sink carries these six variable-selected permission results; other callers pass cataloged constants.
      printf '%s\t%s\n' \
        '$notifications_denied' "$1" \
        '$notifications_enabled' "$1" \
        '$permission_denied' "$1" \
        '$permission_granted' "$1" \
        '$tracking_authorized' "$1" \
        '$tracking_denied' "$1"
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:1637')
      # Notification dispatch forwards one of two names to emitSystemEvent; the sink seam is cataloged at line 886.
      printf '%s\t%s\n' \
        '$notifications_denied' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:886' \
        '$notifications_enabled' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:886'
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:1656')
      # Tracking dispatch forwards one of two names to emitSystemEvent; the sink seam is cataloged at line 886.
      printf '%s\t%s\n' \
        '$tracking_authorized' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:886' \
        '$tracking_denied' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:886'
      ;;
    'Sources/Nuxie/Experiences/ExperienceViewController.swift:1675')
      # Permission dispatch forwards one of two names to emitSystemEvent; the sink seam is cataloged at line 886.
      printf '%s\t%s\n' \
        '$permission_denied' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:886' \
        '$permission_granted' 'Sources/Nuxie/Experiences/ExperienceViewController.swift:886'
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:2616')
      # The scoped milestone stage is constructed from $journey_milestone.
      printf '%s\t%s\n' '$journey_milestone' "$1"
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:3057')
      # The indirect scoped call forwards the fixed denial staged and cataloged at this site.
      printf '%s\t%s\n' \
        '$permission_denied' 'Sources/Nuxie/Journey/JourneyService.swift:3057'
      ;;
    'Sources/Nuxie/Events/EventLog.swift:1951')
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
    'Sources/Nuxie/Events/EventLog.swift:1047' \
      | 'Sources/Nuxie/Events/EventLog.swift:1243' \
      | 'Sources/Nuxie/Events/EventLog.swift:1725' \
      | 'Sources/Nuxie/Events/EventLog.swift:3024')
      # Delivery-path apiClient.trackEvent calls transport an already-built
      # NuxieEvent; the event name originated in a capture lane whose call
      # site is checked above, so these sites are transport, not emission.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:245')
      # Protocol convenience forwards names; concrete SDK callers are checked at their call sites.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:264')
      # The ownership convenience forwards names; its concrete producer is checked at the owned capture call site.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:551' \
      | 'Sources/Nuxie/Events/EventLog.swift:525' \
      | 'Sources/Nuxie/Events/EventLog.swift:539' \
      | 'Sources/Nuxie/Events/EventLog.swift:950' \
      | 'Sources/Nuxie/Events/EventLog.swift:962')
      # EventLog overloads forward names; concrete SDK callers are checked at their call sites.
      return 0
      ;;
    'Sources/Nuxie/Events/EventLog.swift:1320' \
      | 'Sources/Nuxie/Events/EventLog.swift:1341')
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
    'Sources/Nuxie/Journey/JourneyService.swift:1495')
      # Renderer-authored names are curated by the screen emission router before this call.
      return 0
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:2624')
      # This history-only write reuses the milestone stage cataloged at line 2443.
      return 0
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:2616')
      # This direct scoped send reuses the milestone stage cataloged at line 2443.
      return 0
      ;;
    'Sources/Nuxie/Journey/JourneyService.swift:5297')
      # The scoped helper forwards stages whose finite producers are checked at their call sites.
      return 0
      ;;
    'Sources/Nuxie/Journey/Execution/JourneyRunner.swift:3176')
      # Authored send-event names are user-defined; the $event_sent rider below is cataloged.
      return 0
      ;;
    'Sources/Nuxie/Experiences/ExperienceScreenViewController.swift:782')
      # This constructor forwards names checked at the concrete response emitEvent call sites; other names are authored.
      return 0
      ;;
    'Sources/Nuxie/Experiences/ExperienceScreenViewController.swift:710')
      # Renderer-reported event names are authored; reserved response names use the concrete calls below.
      return 0
      ;;
    'Sources/Nuxie/Experiences/ExperienceScreenViewController.swift:755')
      # Runtime journey and host-command names are variable; reserved response names use the concrete calls above.
      return 0
      ;;
    'Sources/Nuxie/NuxieSDK.swift:1166')
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

# Every path-bearing field is part of the machine contract. Arrays describe
# multiple production lanes in matching order; scalars broadcast to all lanes.
while IFS=$'\t' read -r event_name reason; do
  echo "Catalog event $event_name has invalid semantic fields: $reason" >&2
  status=1
done < <(
  jq -r '
    def strings: type == "string" or
      (type == "array" and length > 0 and all(.[]; type == "string"));
    def bools: type == "boolean" or
      (type == "array" and length > 0 and all(.[]; type == "boolean"));
    to_entries[]
    | .key as $event
    | .value as $row
    | ($row.lane | if type == "array" then length else 1 end) as $lane_count
    | if (($row.lane | strings) and ($row.beforeSend | strings)
        and ($row.endpoint | strings) and ($row.persists | bools)
        and ($row.wire | bools)
        and (($row.beforeSend | type) != "array" or ($row.beforeSend | length) == $lane_count)
        and (($row.endpoint | type) != "array" or ($row.endpoint | length) == $lane_count)
        and (($row.persists | type) != "array" or ($row.persists | length) == $lane_count)
        and (($row.wire | type) != "array" or ($row.wire | length) == $lane_count))
      then empty
      else [$event, "semantic fields must have valid scalar/array types and arrays must align with lane count"] | @tsv
      end
  ' "$catalog"
)

# Independent source-site routing map. Each catalog emitter must appear here,
# and its production lane set must exactly match the catalog lane field.
# This deliberately duplicates the mechanically visible routing choice so a
# coordinated lane+tuple catalog edit cannot validate itself.
production_lane_rows=$'$app_action_requested\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3623
$app_backgrounded\ttrackForTrigger\tSources/Nuxie/Core/AppLifecycleTracker.swift:63
$app_installed\ttrackForTrigger\tSources/Nuxie/Core/AppLifecycleTracker.swift:47
$app_opened\ttrackForTrigger\tSources/Nuxie/Core/AppLifecycleTracker.swift:58
$app_opened\ttrackForTrigger\tSources/Nuxie/Core/AppLifecycleTracker.swift:73
$app_updated\ttrackForTrigger\tSources/Nuxie/Core/AppLifecycleTracker.swift:53
$customer_updated\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3317
$event_sent\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3187
$event_sent\tprocessCapture\tSources/Nuxie/Journey/JourneyService.swift:2757
$event_sent\tprocessCapture\tSources/Nuxie/Journey/JourneyService.swift:3762
$event_sent\tprocessCapture\tSources/Nuxie/Journey/JourneyService.swift:3919
$experience_artifact_load_failed\tprocessCapture\tSources/Nuxie/Experiences/ExperienceViewModel.swift:370
$experience_artifact_load_succeeded\tprocessCapture\tSources/Nuxie/Experiences/ExperienceViewModel.swift:352
$experience_dismissed\tprocessCapture\tSources/Nuxie/Experiences/ExperiencePresentationService.swift:864
$experience_errored\tprocessCapture\tSources/Nuxie/Experiences/ExperiencePresentationService.swift:876
$experience_shown\tprocessCapture\tSources/Nuxie/Experiences/ExperiencePresentationService.swift:432
$experiment_exposure\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3085
$experiment_exposure_error\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3044
$experiment_exposure_fallback\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3101
$feature_used\tstorePreparedEventInHistory\tSources/Nuxie/NuxieSDK.swift:1095
$identify\tprocessCapture\tSources/Nuxie/NuxieSDK.swift:643
$journey_claimed\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:964
$journey_converted\ttrackWithResponse\tSources/Nuxie/Journey/JourneyService.swift:5198
$journey_converted\tcommitServerFacts\tSources/Nuxie/Events/EventLog.swift:1951
$journey_effect_completed\tcommitServerFacts\tSources/Nuxie/Events/EventLog.swift:1951
$journey_effect_requested\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3962
$journey_enrolled\ttrackWithResponse\tSources/Nuxie/Journey/JourneyService.swift:659
$journey_exited\ttrackWithResponse\tSources/Nuxie/Journey/JourneyService.swift:4582
$journey_exited\tcaptureStableSystemEvent\tSources/Nuxie/Journey/JourneyService.swift:4753
$journey_exited\ttrackWithResponse\tSources/Nuxie/Journey/JourneyService.swift:5687
$journey_handoff\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:4216
$journey_milestone\ttrackWithResponse\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:3279
$journey_milestone\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:2616
$journey_parked\tprocessCapture\tSources/Nuxie/Journey/JourneyService.swift:4441
$journey_superseded\tcommitServerFacts\tSources/Nuxie/Events/EventLog.swift:1951
$journey_transition\ttrackWithResponse\tSources/Nuxie/Journey/JourneyService.swift:1361
$journey_transition\ttrackWithResponse\tSources/Nuxie/Journey/JourneyService.swift:1413
$journey_transition\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:1720
$journey_transition\ttrackWithResponse\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:2542
$notifications_denied\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:2510
$notifications_denied\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:886
$notifications_enabled\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:2510
$notifications_enabled\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:886
$permission_denied\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:2510
$permission_denied\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:3057
$permission_denied\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:886
$permission_granted\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:2510
$permission_granted\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:886
$products_unavailable\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:968
$purchase_cancelled\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:2046
$purchase_completed\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:626
$purchase_completed\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:649
$purchase_completed\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:658
$purchase_completed\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:664
$purchase_completed\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionObserver.swift:682
$purchase_completed\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionObserver.swift:714
$purchase_completed\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionObserver.swift:1879
$purchase_completed\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionObserver.swift:1886
$purchase_failed\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:2030
$purchase_failed\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:2088
$purchase_failed\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:2111
$purchase_failed\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:720
$purchase_failed\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:733
$purchase_failed\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:754
$purchase_pending\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:2060
$purchase_synced\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionObserver.swift:1396
$purchase_synced\tcaptureStableSystemEvent\tSources/Nuxie/StoreKit/Transactions/TransactionObserver.swift:1610
$response_set\tnone\tSources/Nuxie/Experiences/ExperienceScreenViewController.swift:744
$response_set\tnone\tSources/Nuxie/Experiences/ExperienceScreenViewController.swift:546
$response_set\tnone\tSources/Nuxie/Experiences/Runtime/ScreenEmissionDispatcher.swift:426
$response_unset\tnone\tSources/Nuxie/Experiences/ExperienceScreenViewController.swift:749
$response_unset\tnone\tSources/Nuxie/Experiences/Runtime/ScreenEmissionDispatcher.swift:429
$restore_completed\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:1174
$restore_failed\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:1183
$restore_failed\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:2134
$restore_no_purchases\ttrackForTrigger\tSources/Nuxie/StoreKit/Transactions/TransactionService.swift:1194
$screen_dismissed\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:750
$screen_shown\tprocessCapture\tSources/Nuxie/Journey/Execution/JourneyRunner.swift:701
$tracking_authorized\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:2510
$tracking_authorized\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:886
$tracking_denied\ttrackForTrigger\tSources/Nuxie/Journey/JourneyService.swift:2510
$tracking_denied\ttrackForTrigger\tSources/Nuxie/Experiences/ExperienceViewController.swift:886'

lane_source_pattern() {
  case "$1" in
    processCapture)
      printf '%s' 'eventLog[.]track[(]|trackWithoutRouting[(]'
      ;;
    trackForTrigger)
      printf '%s' '(trackForTrigger|trackScopedEvent|eventSink[.]emit|emitSystemEvent)[(]'
      ;;
    trackWithResponse)
      printf '%s' 'trackWithResponse[(]'
      ;;
    captureStableSystemEvent)
      printf '%s' '(eventSink[.]capture|captureOnly|captureOwnedJourneySystemEvent)[(]'
      ;;
    storePreparedEventInHistory)
      printf '%s' 'storePreparedEventInHistory[(]'
      ;;
    commitServerFacts)
      printf '%s' 'name:[[:space:]]*fact[.]event[.]rawValue'
      ;;
    none)
      printf '%s' '(emitEvent|ExperienceRendererEvent|ScreenEmission)[(]'
      ;;
    *)
      return 1
      ;;
  esac
}

direct_before_send_policy() {
  case "$1|$2" in
    '$journey_claimed|Sources/Nuxie/Journey/JourneyService.swift:964' \
      | '$journey_handoff|Sources/Nuxie/Journey/JourneyService.swift:4216' \
      | '$journey_milestone|Sources/Nuxie/Journey/JourneyService.swift:2616')
      printf '%s' exempt
      ;;
    '$notifications_denied|Sources/Nuxie/Journey/JourneyService.swift:2510' \
      | '$notifications_enabled|Sources/Nuxie/Journey/JourneyService.swift:2510' \
      | '$permission_denied|Sources/Nuxie/Journey/JourneyService.swift:2510' \
      | '$permission_denied|Sources/Nuxie/Journey/JourneyService.swift:3057' \
      | '$permission_granted|Sources/Nuxie/Journey/JourneyService.swift:2510' \
      | '$tracking_authorized|Sources/Nuxie/Journey/JourneyService.swift:2510' \
      | '$tracking_denied|Sources/Nuxie/Journey/JourneyService.swift:2510')
      printf '%s' governed
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS=$'\t' read -r event_name production_lane emitter; do
  if ! jq -e --arg event_name "$event_name" --arg emitter "$emitter" '
      any(.[$event_name].emitters[]; . == $emitter)
    ' "$catalog" >/dev/null; then
    echo "Production lane map has stale or missing emitter $event_name: $emitter" >&2
    status=1
  fi

  # Permission names at this controller site are selected before crossing a
  # callback boundary; their trackForTrigger behavior is pinned in the Swift
  # conformance table because it is not locally inferable from the source row.
  if [[ "$emitter" == "Sources/Nuxie/Experiences/ExperienceViewController.swift:886" ]]; then
    continue
  fi

  source_path="${emitter%:*}"
  source_line="${emitter##*:}"
  source_radius=5
  if [[ "$emitter" == "Sources/Nuxie/Journey/JourneyService.swift:2616" ]]; then
    # The milestone name is staged here and reaches trackScopedEvent later in
    # the same function after local journey evaluation.
    source_radius=64
  elif [[ "$emitter" == "Sources/Nuxie/NuxieSDK.swift:1095" ]]; then
    # The accepted /i/event response is converted into the exact prepared
    # history event at the end of the same useFeature operation.
    source_radius=80
  elif [[ "$emitter" == "Sources/Nuxie/Journey/JourneyService.swift:964" \
      || "$emitter" == "Sources/Nuxie/Journey/JourneyService.swift:4216" ]]; then
    source_radius=8
  elif [[ "$emitter" == Sources/Nuxie/Experiences/Runtime/ScreenEmissionDispatcher.swift:* ]]; then
    source_radius=10
  fi
  first_line=$((source_line > source_radius ? source_line - source_radius : 1))
  last_line=$((source_line + source_radius))
  expected_pattern="$(lane_source_pattern "$production_lane")"
  if ! sed -n "${first_line},${last_line}p" "$source_path" \
      | grep -Eq "$expected_pattern"; then
    echo "Production site $emitter for $event_name does not exhibit mapped lane $production_lane" >&2
    status=1
  fi

  if [[ "$production_lane" == "trackForTrigger" ]] \
      && before_send="$(direct_before_send_policy "$event_name" "$emitter")"; then
    if ! jq -e --arg event_name "$event_name" --arg policy "$before_send" '
        def many: if type == "array" then . else [.] end;
        .[$event_name] as $row
        | ($row.lane | many) as $lanes
        | ($row.beforeSend | many) as $policies
        | any(range(0; $lanes | length);
            $lanes[.] == "trackForTrigger"
              and (($policies | length) == 1 or $policies[.] == $policy)
              and (($policies | length) != 1 or $policies[0] == $policy))
      ' "$catalog" >/dev/null; then
      echo "Catalog beforeSend for $event_name disagrees with direct source policy $before_send" >&2
      status=1
    fi

    if [[ "$emitter" == "Sources/Nuxie/Journey/JourneyService.swift:2616" ]]; then
      if ! grep -Fq 'trackScopedEvent(stage, properties: properties)' \
          <<< "$(sed -n "${first_line},${last_line}p" "$source_path")" \
          || ! rg -Uq 'private func trackScopedEvent[(][[:space:][:print:]]*applyBeforeSend: Bool = false' \
            Sources/Nuxie/Journey/JourneyService.swift; then
        echo "Production site $emitter no longer proves beforeSend-exempt scoped tracking" >&2
        status=1
      fi
    else
      policy_literal=true
      if [[ "$before_send" == "exempt" ]]; then policy_literal=false; fi
      if ! sed -n "${first_line},${last_line}p" "$source_path" \
          | grep -Eq "applyBeforeSend:[[:space:]]*$policy_literal"; then
        echo "Production site $emitter no longer proves beforeSend-$before_send tracking" >&2
        status=1
      fi
    fi
  fi
done <<< "$production_lane_rows"

while IFS=$'\t' read -r event_name emitter; do
  if ! awk -F $'\t' -v event="$event_name" -v site="$emitter" '
      $1 == event && $3 == site { found = 1 }
      END { exit !found }
    ' <<< "$production_lane_rows"; then
    echo "Catalog emitter has no production lane mapping $event_name: $emitter" >&2
    status=1
  fi
done < <(jq -r 'to_entries[] | .key as $event | .value.emitters[] | [$event, .] | @tsv' "$catalog")

catalog_lane_pairs="$(jq -r '
  def many: if type == "array" then . else [.] end;
  to_entries[]
  | select(.value.status != "delete" and .value.status != "retired")
  | .key as $event | .value.lane | many[] | [$event, .] | @tsv
' "$catalog" | sort -u)"
production_lane_pairs="$(awk -F $'\t' '{ print $1 "\t" $2 }' \
  <<< "$production_lane_rows" | sort -u)"
if [[ "$catalog_lane_pairs" != "$production_lane_pairs" ]]; then
  echo "Catalog lanes differ from the independent production source-site map:" >&2
  diff -u <(printf '%s\n' "$production_lane_pairs") \
    <(printf '%s\n' "$catalog_lane_pairs") >&2 || true
  status=1
fi

# These tuples are derived from the production choke points in EventLog and
# JourneyService. Keeping the validation here makes a metadata-only catalog
# edit fail even when its event name and emitter site remain unchanged.
while IFS=$'\t' read -r event_name lane before_send endpoint persists wire; do
  expected=''
  case "$lane" in
    processCapture|captureStableSystemEvent)
      expected=$'governed\tbatch\ttrue\ttrue'
      ;;
    commitServerFacts)
      expected=$'exempt\tnone\ttrue\tfalse'
      ;;
    none)
      expected=$'exempt\tnone\tfalse\tfalse'
      ;;
    trackWithResponse)
      expected=$'exempt\t/i/event response lane\ttrue\ttrue'
      ;;
    trackForTrigger)
      if [[ "$before_send" != "governed" && "$before_send" != "exempt" ]]; then
        expected=$'governed or exempt\t/i/event response lane\ttrue\ttrue'
      else
        expected="$before_send"$'\t/i/event response lane\ttrue\ttrue'
      fi
      ;;
    storePreparedEventInHistory)
      expected=$'governed\t/i/event response lane\ttrue\ttrue'
      ;;
    *)
      echo "Catalog event $event_name uses unknown production lane '$lane'" >&2
      status=1
      continue
      ;;
  esac
  actual="$before_send"$'\t'"$endpoint"$'\t'"$persists"$'\t'"$wire"
  if [[ "$actual" != "$expected" ]]; then
    echo "Catalog event $event_name lane $lane has semantic tuple [$actual], expected [$expected]" >&2
    status=1
  fi
done < <(
  jq -r '
    def many: if type == "array" then . else [.] end;
    to_entries[]
    | .key as $event
    | .value as $row
    | ($row.lane | many) as $lanes
    | range(0; $lanes | length) as $i
    | def at($value): if ($value | type) == "array" then $value[$i] else $value end;
    [$event, $lanes[$i], at($row.beforeSend), at($row.endpoint),
       (at($row.persists) | tostring), (at($row.wire) | tostring)]
    | @tsv
  ' "$catalog"
)

canonical_markdown_values() {
  local kind="$1"
  local value="$2"
  value="${value//\`/}"
  if [[ "$kind" == "beforeSend" ]]; then
    sed -E 's/[[:space:]]+\/[[:space:]]+/\n/g' <<< "$value"
  else
    sed -E 's/[[:space:]]+or[[:space:]]+/\n/g' <<< "$value"
  fi \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sed '/^$/d' \
    | sort -u \
    | paste -sd '|' -
}

# The Markdown table is a checked projection for beforeSend and endpoint
# (labelled Wire there), not an independently editable summary.
while IFS=$'\t' read -r event_name expected_before expected_endpoint; do
  markdown_row="$(awk -F'|' -v target="\`$event_name\`" '
    {
      name = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == target) { print; exit }
    }
  ' "$catalog_markdown")"
  if [[ -z "$markdown_row" ]]; then
    echo "Markdown event catalog is missing $event_name" >&2
    status=1
    continue
  fi
  IFS='|' read -r _ _ _ _ _ markdown_before markdown_endpoint _ _ <<< "$markdown_row"
  actual_before="$(canonical_markdown_values beforeSend "$markdown_before")"
  actual_endpoint="$(canonical_markdown_values endpoint "$markdown_endpoint")"
  if [[ "$actual_before" != "$expected_before" ]]; then
    echo "Markdown beforeSend for $event_name is '$actual_before', catalog requires '$expected_before'" >&2
    status=1
  fi
  if [[ "$actual_endpoint" != "$expected_endpoint" ]]; then
    echo "Markdown endpoint for $event_name is '$actual_endpoint', catalog requires '$expected_endpoint'" >&2
    status=1
  fi
done < <(
  jq -r '
    def many: if type == "array" then . else [.] end;
    def canonical: many | unique | sort | join("|");
    to_entries[]
    | [.key,
       (.value.beforeSend | canonical),
       (.value.endpoint | many | map(if . == "/i/event response lane" then "/i/event" else . end) | unique | sort | join("|"))]
    | @tsv
  ' "$catalog"
)

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
      && "$emitter" == "Sources/Nuxie/Journey/JourneyService.swift:2616" ]] \
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
