import NuxieRuntimeC

func typecheckNuxieRuntimeC(bytes: UnsafePointer<UInt8>, count: Int) {
    precondition(nux_capi_abi_version() == UInt32(NUX_CAPI_ABI_VERSION))
    var file: OpaquePointer?
    var result: OpaquePointer?
    _ = nux_file_import_with_result(bytes, count, &file, &result)
    _ = nux_capi_result_free(result)
    _ = nux_file_free(file)

    var config = NuxFileImportConfig()
    config.struct_size = UInt32(MemoryLayout<NuxFileImportConfig>.size)
    file = nil
    result = nil
    _ = nux_product_file_import_configured(bytes, count, &config, &file, &result)
    _ = nux_capi_result_free(result)
    _ = nux_file_free(file)

    var operation = NuxMetalRenderOperation()
    operation.struct_size = UInt32(MemoryLayout<NuxMetalRenderOperation>.size)
    operation.drawable_state = UInt32(NUX_METAL_DRAWABLE_STATE_TIMEOUT)
    operation.fit = UInt32(NUX_RENDERER_FIT_CONTAIN_CENTER)
    var outcome = NuxRendererOutcome()
    outcome.struct_size = UInt32(MemoryLayout<NuxRendererOutcome>.size)
}
