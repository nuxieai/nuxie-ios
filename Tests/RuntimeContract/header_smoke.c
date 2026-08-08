#include "nux_runtime.h"

#include <stddef.h>
#include <stdint.h>

_Static_assert(NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_IMAGE == 1,
               "external asset kinds are part of the contract");
_Static_assert(NUX_DIAGNOSTIC_SEVERITY_FATAL == 2,
               "diagnostic severities are part of the contract");
_Static_assert(NUX_SURFACE_DISPOSITION_PRESENTED == 1,
               "surface disposition values are part of the contract");
_Static_assert(NUX_SURFACE_DISPOSITION_FATAL == 9,
               "surface disposition values are part of the contract");
_Static_assert(NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS == 4,
               "player-input query kind is part of the contract");
_Static_assert(NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL == 9,
               "player-input mutation kinds are part of the contract");
_Static_assert(NUX_SCREEN_STATE_MUTATION_KIND_FIRE_INPUT_TRIGGER == 11,
               "player-input mutation kinds are part of the contract");
_Static_assert(NUX_SCREEN_STATE_MUTATION_KIND_SET_VIEW_MODEL == 12,
               "view-model replacement kind is part of the contract");
_Static_assert(NUX_SCREEN_SESSION_OPERATION_KIND_TEXT_RUN_BATCH == 5,
               "text-run operation kind is part of the contract");
_Static_assert(NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND == 5,
               "host-command output kind is part of the contract");
_Static_assert(NUX_SCREEN_VALUE_KIND_LIST_INDEX == 10,
               "list-index value kind is part of the contract");
_Static_assert(NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST_INDEX == 12,
               "list-index schema kind is part of the contract");
_Static_assert(NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE == 1,
               "player-selection branches are part of the contract");
_Static_assert(NUX_SCREEN_PLAYER_SELECTION_STATIC == 5,
               "player-selection branches are part of the contract");
_Static_assert(NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_LINEAR_ANIMATION == 6,
               "player-selection branches are part of the contract");
_Static_assert(NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT == 0,
               "player-selector kinds are part of the contract");
_Static_assert(NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE == 1,
               "player-selector kinds are part of the contract");
_Static_assert(NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION == 2,
               "player-selector kinds are part of the contract");
_Static_assert(NUX_STATUS_RUNTIME_IDENTITY_MISMATCH == 6,
               "runtime identity mismatch has a stable status");
_Static_assert(sizeof(NuxStatus) == sizeof(uint32_t),
               "NuxStatus must remain a 32-bit contract value");
_Static_assert(sizeof(NuxSurfaceDisposition) == sizeof(uint32_t),
               "NuxSurfaceDisposition must remain a 32-bit contract value");
_Static_assert(sizeof(struct NuxByteView) == 16,
               "unexpected NuxByteView layout");
_Static_assert(offsetof(struct NuxByteView, len) == 8,
               "unexpected NuxByteView.len offset");
_Static_assert(sizeof(struct NuxExperienceAuthorizationKey) == 40,
               "unexpected NuxExperienceAuthorizationKey layout");
_Static_assert(offsetof(struct NuxExperienceAuthorizationKey, key_id) == 8,
               "unexpected NuxExperienceAuthorizationKey.key_id offset");
_Static_assert(sizeof(struct NuxExperienceExternalAsset) == 80,
               "unexpected NuxExperienceExternalAsset layout");
_Static_assert(offsetof(struct NuxExperienceExternalAsset, unique_name) == 16,
               "unexpected NuxExperienceExternalAsset.unique_name offset");
_Static_assert(offsetof(struct NuxExperienceExternalAsset, bytes) == 64,
               "unexpected NuxExperienceExternalAsset.bytes offset");
_Static_assert(sizeof(struct NuxExperienceImportRequest) == 72,
               "unexpected NuxExperienceImportRequest layout");
_Static_assert(offsetof(struct NuxExperienceImportRequest, package_bytes) == 8,
               "unexpected NuxExperienceImportRequest.package_bytes offset");
_Static_assert(offsetof(struct NuxExperienceImportRequest, candidate_keys) == 40,
               "unexpected NuxExperienceImportRequest.candidate_keys offset");
_Static_assert(offsetof(struct NuxExperienceImportRequest, external_asset_count) == 64,
               "unexpected NuxExperienceImportRequest.external_asset_count offset");
_Static_assert(sizeof(struct NuxDiagnosticView) == 40,
               "unexpected NuxDiagnosticView layout");
_Static_assert(sizeof(struct NuxScreenSessionDescriptor) == 40,
               "unexpected NuxScreenSessionDescriptor layout");
_Static_assert(offsetof(struct NuxScreenSessionDescriptor, artboard_name) == 8,
               "unexpected NuxScreenSessionDescriptor.artboard_name offset");
_Static_assert(offsetof(struct NuxScreenSessionDescriptor, state_machine_name) == 24,
               "unexpected NuxScreenSessionDescriptor.state_machine_name offset");
_Static_assert(sizeof(struct NuxAppleSurfaceDescriptor) == 12,
               "unexpected NuxAppleSurfaceDescriptor layout");
_Static_assert(offsetof(struct NuxAppleSurfaceDescriptor, pixel_width) == 4,
               "unexpected NuxAppleSurfaceDescriptor.pixel_width offset");
_Static_assert(sizeof(struct NuxFrameOperation) == 40,
               "unexpected NuxFrameOperation layout");
_Static_assert(offsetof(struct NuxFrameOperation, apple_drawable) == 16,
               "unexpected NuxFrameOperation.apple_drawable offset");
_Static_assert(offsetof(struct NuxFrameOperation, completion_context) == 24,
               "unexpected NuxFrameOperation.completion_context offset");
_Static_assert(offsetof(struct NuxFrameOperation, completion_callback) == 32,
               "unexpected NuxFrameOperation.completion_callback offset");

_Static_assert(sizeof(struct NuxScreenConfiguredSessionDescriptor) == 40,
               "unexpected NuxScreenConfiguredSessionDescriptor layout");
_Static_assert(offsetof(struct NuxScreenConfiguredSessionDescriptor,
                        player_kind) == 4,
               "unexpected configured player-kind offset");
_Static_assert(offsetof(struct NuxScreenConfiguredSessionDescriptor,
                        artboard_name) == 8,
               "unexpected configured artboard-name offset");
_Static_assert(offsetof(struct NuxScreenConfiguredSessionDescriptor,
                        player_name) == 24,
               "unexpected configured player-name offset");
_Static_assert(sizeof(struct NuxScreenValueNode) == 88,
               "unexpected NuxScreenValueNode layout");
_Static_assert(offsetof(struct NuxScreenValueNode, instance_id) == 40,
               "unexpected NuxScreenValueNode.instance_id offset");
_Static_assert(offsetof(struct NuxScreenValueNode, string_value) == 56,
               "unexpected NuxScreenValueNode.string_value offset");
_Static_assert(sizeof(struct NuxScreenValueEdge) == 24,
               "unexpected NuxScreenValueEdge layout");
_Static_assert(sizeof(struct NuxScreenValueArena) == 40,
               "unexpected NuxScreenValueArena layout");
_Static_assert(sizeof(struct NuxScreenNewInstance) == 40,
               "unexpected NuxScreenNewInstance layout");
_Static_assert(sizeof(struct NuxScreenInstanceReference) == 16,
               "unexpected NuxScreenInstanceReference layout");
_Static_assert(sizeof(struct NuxScreenStateMutation) == 88,
               "unexpected NuxScreenStateMutation layout");
_Static_assert(offsetof(struct NuxScreenStateMutation, path) == 40,
               "unexpected NuxScreenStateMutation.path offset");
_Static_assert(offsetof(struct NuxScreenStateMutation, input_name) == 56,
               "unexpected NuxScreenStateMutation.input_name offset");
_Static_assert(sizeof(struct NuxScreenStateBatch) == 56,
               "unexpected NuxScreenStateBatch layout");
_Static_assert(offsetof(struct NuxScreenStateBatch, value_arena) == 16,
               "unexpected NuxScreenStateBatch.value_arena offset");
_Static_assert(sizeof(struct NuxScreenTextRunMutation) == 40,
               "unexpected NuxScreenTextRunMutation layout");
_Static_assert(offsetof(struct NuxScreenTextRunMutation, name) == 8,
               "unexpected NuxScreenTextRunMutation.name offset");
_Static_assert(offsetof(struct NuxScreenTextRunMutation, text) == 24,
               "unexpected NuxScreenTextRunMutation.text offset");
_Static_assert(sizeof(struct NuxScreenTextRunBatch) == 24,
               "unexpected NuxScreenTextRunBatch layout");
_Static_assert(offsetof(struct NuxScreenTextRunBatch, mutations) == 8,
               "unexpected NuxScreenTextRunBatch.mutations offset");
_Static_assert(sizeof(struct NuxScreenPointerEvent) == 24,
               "unexpected NuxScreenPointerEvent layout");
_Static_assert(offsetof(struct NuxScreenPointerEvent, timestamp_seconds) == 20,
               "unexpected NuxScreenPointerEvent.timestamp_seconds offset");
_Static_assert(sizeof(struct NuxScreenPointerBatch) == 24,
               "unexpected NuxScreenPointerBatch layout");
_Static_assert(sizeof(struct NuxScreenAdvanceOperation) == 48,
               "unexpected NuxScreenAdvanceOperation layout");
_Static_assert(offsetof(struct NuxScreenAdvanceOperation, apple_drawable) == 24,
               "unexpected NuxScreenAdvanceOperation.apple_drawable offset");
_Static_assert(sizeof(struct NuxScreenQuery) == 8,
               "unexpected NuxScreenQuery layout");
_Static_assert(sizeof(struct NuxScreenQueryBatch) == 24,
               "unexpected NuxScreenQueryBatch layout");
_Static_assert(sizeof(struct NuxScreenSessionOperation) == 48,
               "unexpected NuxScreenSessionOperation layout");
_Static_assert(offsetof(struct NuxScreenSessionOperation, kind) == 4,
               "unexpected NuxScreenSessionOperation.kind offset");
_Static_assert(offsetof(struct NuxScreenSessionOperation, state_batch) == 8,
               "unexpected NuxScreenSessionOperation.state_batch offset");
_Static_assert(offsetof(struct NuxScreenSessionOperation, text_run_batch) == 40,
               "unexpected NuxScreenSessionOperation.text_run_batch offset");
_Static_assert(sizeof(struct NuxScreenPlayerMetadataView) == 64,
               "unexpected NuxScreenPlayerMetadataView layout");
_Static_assert(offsetof(struct NuxScreenPlayerMetadataView, selection) == 8,
               "unexpected NuxScreenPlayerMetadataView.selection offset");
_Static_assert(offsetof(struct NuxScreenPlayerMetadataView, artboard_name) == 16,
               "unexpected NuxScreenPlayerMetadataView.artboard_name offset");
_Static_assert(sizeof(struct NuxScreenPlayerInputView) == 32,
               "unexpected NuxScreenPlayerInputView layout");
_Static_assert(sizeof(struct NuxScreenSchemaView) == 48,
               "unexpected NuxScreenSchemaView layout");
_Static_assert(sizeof(struct NuxScreenSchemaPropertyView) == 80,
               "unexpected NuxScreenSchemaPropertyView layout");
_Static_assert(offsetof(struct NuxScreenSchemaPropertyView,
                        referenced_schema_id) == 56,
               "unexpected referenced-schema offset");
_Static_assert(offsetof(struct NuxScreenSchemaPropertyView,
                        first_enum_label) == 72,
               "unexpected enum-label span offset");
_Static_assert(sizeof(struct NuxScreenEnumLabelView) == 24,
               "unexpected NuxScreenEnumLabelView layout");
_Static_assert(sizeof(struct NuxScreenInstanceTemplateView) == 40,
               "unexpected NuxScreenInstanceTemplateView layout");
_Static_assert(sizeof(struct NuxScreenInstanceView) == 56,
               "unexpected NuxScreenInstanceView layout");
_Static_assert(sizeof(struct NuxScreenValueRootView) == 16,
               "unexpected NuxScreenValueRootView layout");
_Static_assert(sizeof(struct NuxScreenCreatedInstanceView) == 16,
               "unexpected NuxScreenCreatedInstanceView layout");
_Static_assert(sizeof(struct NuxScreenEventPropertyView) == 40,
               "unexpected NuxScreenEventPropertyView layout");
_Static_assert(sizeof(struct NuxScreenOutputView) == 160,
               "unexpected NuxScreenOutputView layout");
_Static_assert(offsetof(struct NuxScreenOutputView, payload_root_index) == 12,
               "unexpected NuxScreenOutputView.payload_root_index offset");
_Static_assert(offsetof(struct NuxScreenOutputView, sequence) == 24,
               "unexpected NuxScreenOutputView.sequence offset");
_Static_assert(offsetof(struct NuxScreenOutputView, name) == 72,
               "unexpected NuxScreenOutputView.name offset");
_Static_assert(offsetof(struct NuxScreenOutputView, has_open_url) == 120,
               "unexpected NuxScreenOutputView.has_open_url offset");
_Static_assert(offsetof(struct NuxScreenOutputView, open_url) == 128,
               "unexpected NuxScreenOutputView.open_url offset");
_Static_assert(offsetof(struct NuxScreenOutputView, open_url_target) == 144,
               "unexpected NuxScreenOutputView.open_url_target offset");

static void typecheck_product_api(void)
{
    NuxStatus (*bind_runtime)(const uint8_t*,
                              uint64_t,
                              const uint8_t*,
                              uint64_t,
                              const struct NuxRuntimeBinding**) =
        nux_runtime_bind;
    NuxStatus (*create_context)(const struct NuxRuntimeBinding*,
                                const struct NuxExperienceImportRequest*,
                                struct NuxExperienceContext**,
                                struct NuxOperationResult**) =
        nux_experience_context_create_bound;
    NuxStatus (*create_context_unbound)(
        const struct NuxExperienceImportRequest*,
        struct NuxExperienceContext**,
        struct NuxOperationResult**) =
        nux_experience_context_create;
    NuxStatus (*create_session)(const struct NuxExperienceContext*,
                                const struct NuxScreenSessionDescriptor*,
                                struct NuxScreenSession**,
                                struct NuxOperationResult**) =
        nux_screen_session_create;
    NuxStatus (*create_configured_session)(
        const struct NuxExperienceContext*,
        const struct NuxScreenConfiguredSessionDescriptor*,
        struct NuxScreenSession**,
        struct NuxScreenSessionResult**) =
        nux_screen_session_create_configured;
    NuxStatus (*attach_surface)(const struct NuxScreenSession*,
                                const struct NuxAppleSurfaceDescriptor*,
                                struct NuxAppleSurface**,
                                struct NuxOperationResult**) =
        nux_screen_session_attach_apple_surface;
    NuxStatus (*reattach_surface)(const struct NuxAppleSurface*,
                                  const struct NuxAppleSurfaceDescriptor*,
                                  struct NuxOperationResult**) =
        nux_apple_surface_reattach;
    NuxStatus (*copy_metal_device)(const struct NuxAppleSurface*,
                                   void**,
                                   struct NuxOperationResult**) =
        nux_apple_surface_copy_metal_device;
    NuxStatus (*advance)(const struct NuxScreenSession*,
                         const struct NuxFrameOperation*,
                         struct NuxOperationResult**) =
        nux_screen_session_advance;
    NuxStatus (*perform)(const struct NuxScreenSession*,
                         const struct NuxScreenSessionOperation*,
                         struct NuxScreenSessionResult**) =
        nux_screen_session_perform;
    NuxStatus (*session_result_status)(const struct NuxScreenSessionResult*) =
        nux_screen_session_result_status;
    NuxStatus (*player_metadata)(const struct NuxScreenSessionResult*,
                                 struct NuxScreenPlayerMetadataView*) =
        nux_screen_session_result_player_metadata;
    uint64_t (*player_input_count)(const struct NuxScreenSessionResult*) =
        nux_screen_session_result_player_input_count;
    NuxStatus (*player_input_at)(const struct NuxScreenSessionResult*,
                                 uint64_t,
                                 struct NuxScreenPlayerInputView*) =
        nux_screen_session_result_player_input_at;
    uint64_t (*value_node_count)(const struct NuxScreenSessionResult*) =
        nux_screen_session_result_value_node_count;
    NuxStatus (*value_node_at)(const struct NuxScreenSessionResult*,
                               uint64_t,
                               struct NuxScreenValueNode*) =
        nux_screen_session_result_value_node_at;
    uint64_t (*output_count)(const struct NuxScreenSessionResult*) =
        nux_screen_session_result_output_count;
    NuxStatus (*output_at)(const struct NuxScreenSessionResult*,
                           uint64_t,
                           struct NuxScreenOutputView*) =
        nux_screen_session_result_output_at;
    NuxStatus (*wake_after_seconds)(const struct NuxScreenSessionResult*,
                                    double*) =
        nux_screen_session_result_wake_after_seconds;
    void (*free_session_result)(struct NuxScreenSessionResult*) =
        nux_screen_session_result_free;
    NuxStatus (*authenticated_key_id)(const struct NuxOperationResult*,
                                      struct NuxByteView*) =
        nux_operation_result_authenticated_key_id;
    uint64_t (*diagnostic_count)(const struct NuxOperationResult*) =
        nux_operation_result_diagnostic_count;
    NuxStatus (*diagnostic_at)(const struct NuxOperationResult*,
                               uint64_t,
                               struct NuxDiagnosticView*) =
        nux_operation_result_diagnostic_at;

    (void)bind_runtime;
    (void)create_context;
    (void)create_context_unbound;
    (void)create_session;
    (void)create_configured_session;
    (void)attach_surface;
    (void)reattach_surface;
    (void)copy_metal_device;
    (void)advance;
    (void)perform;
    (void)session_result_status;
    (void)player_metadata;
    (void)player_input_count;
    (void)player_input_at;
    (void)value_node_count;
    (void)value_node_at;
    (void)output_count;
    (void)output_at;
    (void)wake_after_seconds;
    (void)free_session_result;
    (void)authenticated_key_id;
    (void)diagnostic_count;
    (void)diagnostic_at;
}

static NuxStatus bind_and_create_context(
    const uint8_t* expected_runtime_version,
    uint64_t expected_runtime_version_len,
    const uint8_t* expected_source_revision,
    uint64_t expected_source_revision_len,
    const struct NuxExperienceImportRequest* request,
    struct NuxExperienceContext** out_context,
    struct NuxOperationResult** out_result)
{
    const struct NuxRuntimeBinding* binding = NULL;
    NuxStatus status =
        nux_runtime_bind(expected_runtime_version,
                         expected_runtime_version_len,
                         expected_source_revision,
                         expected_source_revision_len,
                         &binding);
    if (status != NUX_STATUS_OK) {
        return status;
    }
    return nux_experience_context_create_bound(binding,
                                           request,
                                           out_context,
                                           out_result);
}

int main(void)
{
    typecheck_product_api();
    (void)bind_and_create_context;
    return 0;
}
