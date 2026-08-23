#!/usr/bin/env python3
"""Focused tests for the public/SPI API baseline tooling."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from unittest import mock


SCRIPTS_DIRECTORY = __file__.rsplit("/", 1)[0]


def load_script(module_name: str, filename: str):
    spec = importlib.util.spec_from_file_location(
        module_name,
        f"{SCRIPTS_DIRECTORY}/{filename}",
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


extract_public_api = load_script("extract_public_api", "extract-public-api.py")
check_spi_leaks = load_script(
    "check_public_api_spi_leaks",
    "check-public-api-spi-leaks.py",
)


def declaration(usr: str, name: str, **extra):
    return {
        "moduleName": "Nuxie",
        "usr": usr,
        "kind": "TypeDecl",
        "printedName": name,
        **extra,
    }


class ExtractPublicAPITests(unittest.TestCase):
    def test_inventories_partition_recursive_declarations_by_usr(self):
        digest = {
            "ABIRoot": {
                "children": [
                    declaration("customer", "Customer"),
                    declaration("implicit", "Implicit", implicit=True),
                    declaration("shared", "CustomerShared"),
                    {
                        "spi_group_names": ["Testing"],
                        "nestedMembers": [
                            declaration("inherited-spi", "InheritedSPI"),
                            declaration("shared", "SPIShared"),
                            declaration("implicit-spi", "ImplicitSPI", implicit=True),
                        ],
                    },
                ],
                # Digester accessors are not guaranteed to live under `children`.
                "accessorRecord": {
                    "getter": declaration("accessor", "Customer.getter")
                },
            }
        }

        customer, spi = extract_public_api.inventories(digest)
        customer_usrs = {row.split("\t", 1)[0] for row in customer}
        spi_usrs = {row.split("\t", 1)[0] for row in spi}

        self.assertEqual(customer_usrs, {"accessor", "customer"})
        self.assertEqual(spi_usrs, {"inherited-spi", "shared"})
        self.assertTrue(customer_usrs.isdisjoint(spi_usrs))
        self.assertNotIn("implicit", customer_usrs | spi_usrs)
        self.assertNotIn("implicit-spi", customer_usrs | spi_usrs)

    def test_customer_digest_removes_the_entire_spi_subtree(self):
        customer = declaration("customer", "Customer")
        implicit = declaration("implicit", "Implicit", implicit=True)
        digest = {
            "ABIRoot": {
                "children": [
                    customer,
                    {
                        "spi_group_names": ["Testing"],
                        "nestedMembers": [
                            declaration("inherited-spi", "InheritedSPI")
                        ],
                    },
                    implicit,
                ],
                "metadata": {"formatVersion": "1.0"},
            }
        }

        filtered = extract_public_api.customer_digest(digest)

        self.assertEqual(
            filtered,
            {
                "ABIRoot": {
                    "children": [customer, implicit],
                    "metadata": {"formatVersion": "1.0"},
                }
            },
        )


class CheckPublicAPISPILeaksTests(unittest.TestCase):
    def test_main_rejects_same_usr_even_when_inventory_rows_differ(self):
        with tempfile.TemporaryDirectory() as directory:
            customer_path = check_spi_leaks.Path(directory) / "customer.txt"
            spi_path = check_spi_leaks.Path(directory) / "spi.txt"
            customer_path.write_text(
                "same-usr\tTypeDecl\tCustomerSpelling\n",
                encoding="utf-8",
            )
            spi_path.write_text(
                "same-usr\tFuncDecl\tDifferentSPISpelling()\n",
                encoding="utf-8",
            )

            class Arguments:
                customer_inventory = customer_path
                spi_inventory = spi_path

            with tempfile.TemporaryFile(mode="w+") as stderr:
                with mock.patch.object(
                    check_spi_leaks,
                    "parse_arguments",
                    return_value=Arguments(),
                ), mock.patch.object(check_spi_leaks.sys, "stderr", stderr):
                    result = check_spi_leaks.main()

                stderr.seek(0)
                diagnostic = stderr.read()

        self.assertEqual(result, 1)
        self.assertIn("same-usr\tTypeDecl\tCustomerSpelling", diagnostic)
        self.assertIn("contains SPI declarations", diagnostic)

    def test_declarations_by_usr_rejects_malformed_inventory_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            inventory_path = check_spi_leaks.Path(directory) / "malformed.txt"
            inventory_path.write_text(
                "valid-usr\tTypeDecl\tValid\nmissing-fields\tTypeDecl\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                r"malformed\.txt:2: expected USR, kind, and printed name",
            ):
                check_spi_leaks.declarations_by_usr(inventory_path)


if __name__ == "__main__":
    unittest.main()
