#!/usr/bin/env python3

import importlib.util
import pathlib
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "apple_runtime_contract", SCRIPT_DIR / "apple_runtime_contract.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load apple_runtime_contract.py")
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)


class SlimRuntimeContractTests(unittest.TestCase):
    def test_accepts_an_exact_product_neutral_symbol_set(self) -> None:
        header = """
        uint32_t nux_capi_abi_version(void);
        NuxStatus nux_file_import_metal(NuxRenderer *renderer,
            const uint8_t *bytes, size_t len);
        NuxStatus nux_renderer_new_metal(uint32_t width, uint32_t height);
        """
        exports = """
        _nux_capi_abi_version
        _nux_file_import_metal
        _nux_renderer_new_metal
        _unrelated_system_symbol
        """

        CONTRACT.validate_symbols(header, exports)

    def test_accepts_the_single_authored_data_extension_symbol(self) -> None:
        header = """
        NuxStatus nux_product_file_import_configured(
            NuxRenderer *renderer, const uint8_t *bytes, size_t len);
        """
        exports = """
        _nux_product_file_import_configured
        """

        CONTRACT.validate_symbols(header, exports)

    def test_rejects_every_retired_product_function_family(self) -> None:
        for function in (
            "nux_runtime_bind",
            "nux_experience_context_create",
            "nux_screen_session_create",
            "nux_flow_session_advance",
            "nux_operation_result_status",
            "nux_apple_surface_copy_metal_device",
        ):
            with self.subTest(function=function):
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "removed product ABI identifiers"
                ):
                    CONTRACT.expected_symbols(f"NuxStatus {function}(void);")

    def test_rejects_retired_product_types_even_without_functions(self) -> None:
        for type_name in (
            "NuxRuntimeBinding",
            "NuxExperienceContext",
            "NuxScreenSession",
            "NuxFlowSession",
            "NuxOperationResult",
            "NuxAppleSurface",
        ):
            with self.subTest(type_name=type_name):
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "removed product ABI identifiers"
                ):
                    CONTRACT.expected_symbols(
                        f"typedef struct {type_name} {type_name};\n"
                        "NuxStatus nux_file_free(void *file);"
                    )

    def test_rejects_missing_and_extra_public_nux_symbols(self) -> None:
        header = """
        NuxStatus nux_file_free(void *file);
        NuxStatus nux_player_free(void *player);
        """

        for exports in (
            "_nux_file_free\n",
            "_nux_file_free\n_nux_player_free\n_nux_unpublished_extra\n",
        ):
            with self.subTest(exports=exports):
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "public symbol set differs"
                ):
                    CONTRACT.validate_symbols(header, exports)


if __name__ == "__main__":
    unittest.main()
