#!/usr/bin/env python3
"""Reject SPI USRs from a customer API declaration inventory."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def declarations_by_usr(path: Path) -> dict[str, str]:
    declarations: dict[str, str] = {}
    with path.open(encoding="utf-8") as source:
        for line_number, raw_line in enumerate(source, start=1):
            declaration = raw_line.rstrip("\n")
            if not declaration:
                continue
            fields = declaration.split("\t", 2)
            if len(fields) != 3 or not fields[0]:
                raise ValueError(
                    f"{path}:{line_number}: expected USR, kind, and printed name"
                )
            declarations[fields[0]] = declaration
    return declarations


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="fail if a customer API inventory contains an SPI USR"
    )
    parser.add_argument("customer_inventory", type=Path)
    parser.add_argument("spi_inventory", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    customer = declarations_by_usr(arguments.customer_inventory)
    spi = declarations_by_usr(arguments.spi_inventory)
    leaked_usrs = sorted(customer.keys() & spi.keys())

    if not leaked_usrs:
        return 0

    print(
        f"Customer API inventory {arguments.customer_inventory} contains SPI declarations:",
        file=sys.stderr,
    )
    for usr in leaked_usrs:
        print(f"  {customer[usr]}", file=sys.stderr)
    print(
        "SPI declarations are tracked only in the SPI API baseline.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
