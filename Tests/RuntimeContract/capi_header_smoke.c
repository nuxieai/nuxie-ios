#include "nux_product_extension.h"

#include <stddef.h>
#include <stdint.h>

_Static_assert(NUX_CAPI_ABI_VERSION == 3, "unexpected portable ABI version");
_Static_assert(sizeof(NuxStatus) == sizeof(uint32_t), "status must be fixed-width");
_Static_assert(sizeof(struct NuxStringView) == 16, "unexpected string-view layout");
_Static_assert(sizeof(struct NuxPlayerStep) == 56, "unexpected player-step layout");
_Static_assert(sizeof(struct NuxRendererOutcome) == 48, "unexpected renderer outcome layout");
_Static_assert(sizeof(struct NuxMetalRenderOperation) == 48, "unexpected Metal operation layout");
_Static_assert(NUX_RENDERER_FIT_NONE == 0, "unexpected raw renderer-fit value");
_Static_assert(NUX_RENDERER_FIT_CONTAIN_CENTER == 1, "unexpected contain renderer-fit value");

void typecheck_nux_capi(const uint8_t *bytes, size_t len) {
    struct NuxFile *file = NULL;
    struct NuxCapiResult *result = NULL;
    (void)nux_file_import_with_result(bytes, len, &file, &result);
    (void)nux_capi_result_free(result);
    (void)nux_file_free(file);

    struct NuxFileImportConfig config = {0};
    config.struct_size = (uint32_t)sizeof(config);
    file = NULL;
    result = NULL;
    (void)nux_product_file_import_configured(
        bytes, len, &config, &file, &result);
    (void)nux_capi_result_free(result);
    (void)nux_file_free(file);

    struct NuxRenderer *renderer = NULL;
    result = NULL;
    (void)nux_renderer_new_metal(1, 1, &renderer, &result);
    (void)nux_capi_result_free(result);
    (void)nux_renderer_free(renderer);
}
