#!/usr/bin/env python3
"""Split swift-api-digester JSON into customer and SPI API baselines."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Iterator


def declarations(
    value: Any,
    inherited_spi: bool = False,
) -> Iterator[tuple[bool, str, str]]:
    if isinstance(value, dict):
        is_spi = inherited_spi or bool(value.get("spi_group_names"))
        usr = value.get("usr")
        kind = value.get("kind")
        if (
            value.get("moduleName") == "Nuxie"
            and isinstance(usr, str)
            and isinstance(kind, str)
            and value.get("implicit") is not True
        ):
            declaration = "\t".join((usr, kind, value.get("printedName", "")))
            yield is_spi, usr, declaration
        for child in value.values():
            yield from declarations(child, is_spi)
    elif isinstance(value, list):
        for child in value:
            yield from declarations(child, inherited_spi)


def inventories(digest: Any) -> tuple[list[str], list[str]]:
    declarations_by_usr: dict[str, str] = {}
    spi_usrs: set[str] = set()

    for is_spi, usr, declaration in declarations(digest):
        declarations_by_usr[usr] = declaration
        if is_spi:
            spi_usrs.add(usr)

    customer = sorted(
        declaration
        for usr, declaration in declarations_by_usr.items()
        if usr not in spi_usrs
    )
    spi = sorted(
        declaration
        for usr, declaration in declarations_by_usr.items()
        if usr in spi_usrs
    )
    return customer, spi


REMOVED = object()


def customer_digest(value: Any, spi_usrs: frozenset[str] = frozenset()) -> Any:
    """Drop SPI-marked subtrees and any declaration whose USR is SPI.

    A USR can appear both unmarked and beneath an SPI node; the inventory
    assigns such duplicates to SPI, so the customer digest must drop the
    unmarked copy too or the compatibility baseline would retain an SPI
    declaration the text inventory rejects.
    """
    if isinstance(value, dict):
        if value.get("spi_group_names"):
            return REMOVED
        if isinstance(value.get("usr"), str) and value["usr"] in spi_usrs:
            return REMOVED

        filtered: dict[str, Any] = {}
        for key, child in value.items():
            filtered_child = customer_digest(child, spi_usrs)
            if filtered_child is not REMOVED:
                filtered[key] = filtered_child
        return filtered

    if isinstance(value, list):
        filtered_children = []
        for child in value:
            filtered_child = customer_digest(child, spi_usrs)
            if filtered_child is not REMOVED:
                filtered_children.append(filtered_child)
        return filtered_children

    return value


def inventory_text(declarations: list[str]) -> str:
    return "".join(f"{declaration}\n" for declaration in declarations)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "emit the customer declaration inventory and optionally write the "
            "SPI inventory and customer-only digester JSON"
        )
    )
    parser.add_argument("digest", type=Path, metavar="API_DIGEST.json")
    parser.add_argument(
        "--spi-output",
        type=Path,
        metavar="PATH",
        help="write the SPI-only declaration inventory to PATH",
    )
    parser.add_argument(
        "--customer-digest-output",
        type=Path,
        metavar="PATH",
        help="write digester JSON with SPI declaration subtrees removed to PATH",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()

    with arguments.digest.open(encoding="utf-8") as source:
        digest = json.load(source)

    customer, spi = inventories(digest)
    sys.stdout.write(inventory_text(customer))

    if arguments.spi_output is not None:
        arguments.spi_output.write_text(inventory_text(spi), encoding="utf-8")

    if arguments.customer_digest_output is not None:
        spi_usrs = frozenset(
            declaration.split("\t", 1)[0] for declaration in spi
        )
        filtered_digest = customer_digest(digest, spi_usrs)
        if filtered_digest is REMOVED:
            raise ValueError("swift-api-digester root unexpectedly belongs to SPI")
        with arguments.customer_digest_output.open("w", encoding="utf-8") as output:
            json.dump(filtered_digest, output, indent=2)
            output.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
