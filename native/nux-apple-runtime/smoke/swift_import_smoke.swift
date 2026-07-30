import NuxieRuntime

func typecheckNuxieRuntimeModule(
    bytes: UnsafePointer<UInt8>,
    count: UInt64,
    expectedRuntimeVersion: UnsafePointer<UInt8>,
    expectedRuntimeVersionCount: UInt64,
    expectedSourceRevision: UnsafePointer<UInt8>,
    expectedSourceRevisionCount: UInt64,
    expectedExperienceID: UnsafePointer<CChar>,
    expectedBuildID: UnsafePointer<CChar>
) {
    _ = NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT
    _ = NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE
    _ = NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION
    _ = NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_LINEAR_ANIMATION

    let byteView = NuxByteView(data: bytes, len: count)
    var importRequest = NuxExperienceImportRequest(
        struct_size: UInt32(MemoryLayout<NuxExperienceImportRequest>.size),
        package_bytes: byteView,
        expected_experience_id: expectedExperienceID,
        expected_build_id: expectedBuildID,
        candidate_keys: nil,
        candidate_key_count: 0,
        external_assets: nil,
        external_asset_count: 0
    )
    _ = NuxExperienceAuthorizationKey(
        struct_size: UInt32(MemoryLayout<NuxExperienceAuthorizationKey>.size),
        key_id: NuxByteView(data: nil, len: 0),
        ed25519_public_key: NuxByteView(data: nil, len: 0)
    )
    _ = NuxExperienceExternalAsset(
        struct_size: UInt32(MemoryLayout<NuxExperienceExternalAsset>.size),
        kind: UInt32(NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_IMAGE),
        asset_id: 0,
        required: false,
        provided: false,
        unique_name: NuxByteView(data: nil, len: 0),
        source_key: NuxByteView(data: nil, len: 0),
        expected_sha256: NuxByteView(data: nil, len: 0),
        bytes: NuxByteView(data: nil, len: 0)
    )
    var diagnosticView = NuxDiagnosticView(
        struct_size: UInt32(MemoryLayout<NuxDiagnosticView>.size),
        severity: UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG),
        code: NuxByteView(data: nil, len: 0),
        message: NuxByteView(data: nil, len: 0)
    )
    _ = NuxScreenSessionDescriptor(
        struct_size: UInt32(MemoryLayout<NuxScreenSessionDescriptor>.size),
        artboard_name: NuxByteView(data: nil, len: 0),
        state_machine_name: NuxByteView(data: nil, len: 0)
    )
    _ = NuxFrameOperation(
        struct_size: UInt32(MemoryLayout<NuxFrameOperation>.size),
        elapsed_seconds: 0,
        render: false,
        apple_drawable: nil,
        completion_context: nil,
        completion_callback: nil
    )
    _ = NuxAppleSurfaceDescriptor(
        struct_size: UInt32(MemoryLayout<NuxAppleSurfaceDescriptor>.size),
        pixel_width: 1,
        pixel_height: 1
    )
    _ = NuxScreenConfiguredSessionDescriptor(
        struct_size: UInt32(MemoryLayout<NuxScreenConfiguredSessionDescriptor>.size),
        player_kind: UInt32(NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT),
        artboard_name: NuxByteView(data: nil, len: 0),
        player_name: NuxByteView(data: nil, len: 0)
    )
    _ = NuxScreenValueNode(
        struct_size: UInt32(MemoryLayout<NuxScreenValueNode>.size),
        kind: UInt32(NUX_SCREEN_VALUE_KIND_NULL),
        number_value: 0,
        color_value: 0,
        bool_value: 0,
        first_edge: 0,
        edge_count: 0,
        has_instance_id: 0,
        instance_id: 0,
        identity_value: 0,
        string_value: NuxByteView(data: nil, len: 0),
        schema_id: NuxByteView(data: nil, len: 0)
    )
    _ = NuxScreenPointerEvent(
        struct_size: UInt32(MemoryLayout<NuxScreenPointerEvent>.size),
        kind: UInt32(NUX_SCREEN_POINTER_EVENT_KIND_DOWN),
        pointer_id: 1,
        x: 0,
        y: 0,
        timestamp_seconds: 0
    )
    _ = NuxScreenAdvanceOperation(
        struct_size: UInt32(MemoryLayout<NuxScreenAdvanceOperation>.size),
        timestamp_seconds: 0,
        delta_seconds: 0,
        render: 0,
        apple_drawable: nil,
        completion_context: nil,
        completion_callback: nil
    )
    _ = NuxScreenQuery(
        struct_size: UInt32(MemoryLayout<NuxScreenQuery>.size),
        kind: UInt32(NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS)
    )
    let zeroInstanceReference = NuxScreenInstanceReference(
        kind: 0,
        local_id: 0,
        instance_id: 0
    )
    _ = NuxScreenStateMutation(
        struct_size: UInt32(MemoryLayout<NuxScreenStateMutation>.size),
        kind: UInt32(NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL),
        instance: zeroInstanceReference,
        item: zeroInstanceReference,
        path: NuxByteView(data: nil, len: 0),
        input_name: byteView,
        value_root_index: 0,
        index: 0,
        other_index: 0
    )
    _ = NuxScreenTextRunMutation(
        struct_size: UInt32(MemoryLayout<NuxScreenTextRunMutation>.size),
        name: byteView,
        text: NuxByteView(data: nil, len: 0)
    )
    _ = NuxScreenTextRunBatch(
        struct_size: UInt32(MemoryLayout<NuxScreenTextRunBatch>.size),
        mutations: nil,
        mutation_count: 0
    )
    _ = NuxScreenSessionOperation(
        struct_size: UInt32(MemoryLayout<NuxScreenSessionOperation>.size),
        kind: UInt32(NUX_SCREEN_SESSION_OPERATION_KIND_QUERY),
        state_batch: nil,
        pointer_batch: nil,
        advance: nil,
        query_batch: nil,
        text_run_batch: nil
    )
    var playerMetadata = NuxScreenPlayerMetadataView(
        struct_size: UInt32(MemoryLayout<NuxScreenPlayerMetadataView>.size),
        kind: UInt32(NUX_SCREEN_PLAYER_KIND_STATIC),
        selection: UInt32(NUX_SCREEN_PLAYER_SELECTION_STATIC),
        player_index: UInt32.max,
        artboard_name: NuxByteView(data: nil, len: 0),
        player_name: NuxByteView(data: nil, len: 0),
        min_x: 0,
        min_y: 0,
        max_x: 0,
        max_y: 0
    )
    var outputView = NuxScreenOutputView(
        struct_size: UInt32(MemoryLayout<NuxScreenOutputView>.size),
        phase: UInt32(NUX_SCREEN_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS),
        kind: UInt32(NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT),
        payload_root_index: UInt32.max,
        has_origin_mutation_id: 0,
        has_instance_id: 0,
        sequence: 0,
        cycle: 0,
        origin_mutation_id: 0,
        instance_id: 0,
        event_type: 0,
        first_event_property: 0,
        event_property_count: 0,
        delay_seconds: 0,
        name: NuxByteView(data: nil, len: 0),
        path: NuxByteView(data: nil, len: 0),
        payload: NuxByteView(data: nil, len: 0),
        has_open_url: 0,
        open_url: NuxByteView(data: nil, len: 0),
        open_url_target: NuxByteView(data: nil, len: 0)
    )
    var playerInput = NuxScreenPlayerInputView(
        struct_size: UInt32(MemoryLayout<NuxScreenPlayerInputView>.size),
        kind: UInt32(NUX_SCREEN_PLAYER_INPUT_KIND_BOOL),
        value_root_index: 0,
        name: NuxByteView(data: nil, len: 0)
    )
    var metalDevice: UnsafeMutableRawPointer?
    var binding: OpaquePointer?
    var context: OpaquePointer?
    var result: OpaquePointer?
    var sessionResult: OpaquePointer?
    var authenticatedKeyID = NuxByteView(data: nil, len: 0)
    let bindingStatus = nux_runtime_bind(
        expectedRuntimeVersion,
        expectedRuntimeVersionCount,
        expectedSourceRevision,
        expectedSourceRevisionCount,
        &binding
    )
    if bindingStatus == NUX_STATUS_OK {
        _ = nux_experience_context_create_bound(
            binding,
            &importRequest,
            &context,
            &result
        )
    }
    _ = nux_experience_context_create(&importRequest, &context, &result)
    _ = nux_apple_surface_copy_metal_device(nil, &metalDevice, &result)
    _ = nux_operation_result_authenticated_key_id(result, &authenticatedKeyID)
    _ = nux_operation_result_diagnostic_count(result)
    _ = nux_operation_result_diagnostic_at(result, 0, &diagnosticView)
    _ = nux_screen_session_create_configured(nil, nil, nil, &sessionResult)
    _ = nux_screen_session_perform(nil, nil, &sessionResult)
    _ = nux_screen_session_result_status(sessionResult)
    _ = nux_screen_session_result_player_metadata(sessionResult, &playerMetadata)
    _ = nux_screen_session_result_player_input_count(sessionResult)
    _ = nux_screen_session_result_player_input_at(sessionResult, 0, &playerInput)
    _ = nux_screen_session_result_output_count(sessionResult)
    _ = nux_screen_session_result_output_at(sessionResult, 0, &outputView)
    nux_screen_session_result_free(sessionResult)
    _ = NUX_SURFACE_DISPOSITION_PRESENTED
}
