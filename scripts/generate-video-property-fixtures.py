#!/usr/bin/env python3
"""Add ordinary ViewModel bindings to the published video qualification scenes.

Input is the original publisher corpus, before these bindings were added. Keep
all original records and property bytes so component identities stay unchanged.
The endpoint uses the ordinary frame scene and bound pause/seek values.
"""
import argparse
import json
from pathlib import Path
import struct


def varuint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def read_scene(data):
    assert data[:4] == b"RIVE"
    offset = 4

    def uint():
        nonlocal offset
        value, shift = 0, 0
        while True:
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
            shift += 7

    version = [uint(), uint(), uint()]
    keys = []
    while key := uint():
        keys.append(key)
    types = {}
    for start in range(0, len(keys), 4):
        packed = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        for index, key in enumerate(keys[start:start + 4]):
            types[key] = (packed >> (index * 2)) & 3
    # These native registry fields are absent from the original header table.
    types.update({196: 0, 593: 0, 606: 0, 588: 1})
    records = []
    while offset < len(data):
        type_key, properties = uint(), {}
        while key := uint():
            start = offset
            kind = types[key]
            if kind == 0:
                uint()
            elif kind == 1:
                size = uint()
                offset += size
            else:
                offset += 4
            properties[key] = data[start:offset]
        records.append((type_key, properties))
    return version, types, records


def string(value):
    data = value.encode()
    return varuint(len(data)) + data


# Web property names and native keys. Their values live in root model zero;
# list rows resolve this model through their parent data context.
PROPERTIES = [
    ("paused", 60016, True, False),
    ("muted", 60005, True, False),
    ("volume", 60006, False, 1.0),
    ("loop", 60004, True, True),
    ("playback-rate", 60007, False, 1.0),
    ("current-time", 60017, False, 0.0),
]


def migrate(source, endpoint=False):
    version, types, records = read_scene(source)
    root = next(i for i, (ty, _) in enumerate(records) if ty == 435)
    end = next(i for i in range(root + 1, len(records)) if records[i][0] == 435)
    assert all(p.get(557) != string("paused") for _, p in records[root + 1:end]), "Use the original publisher corpus"
    first_property = end - root - 1
    types.update({557: 1, 554: 0, 575: 2, 593: 0, 586: 0, 587: 0, 588: 1})
    defaults = {name: value for name, _, _, value in PROPERTIES}
    defaults["muted"] = any(p.get(60005) == varuint(1) for ty, p in records if ty == 60001)
    if endpoint:
        defaults.update(paused=True, muted=True, loop=False)
    output = []
    in_root_instance = False
    for index, (ty, properties) in enumerate(records):
        if index == end:
            output.extend((448 if boolean else 431, {557: string(name)}) for name, _, boolean, _ in PROPERTIES)
        if in_root_instance and ty in (437, 1):
            for number, (name, _, boolean, _) in enumerate(PROPERTIES, first_property):
                value = defaults[name]
                output.append((449 if boolean else 442, {
                    554: varuint(number),
                    593 if boolean else 575: varuint(int(value)) if boolean else struct.pack("<f", value),
                }))
            in_root_instance = False
        if ty == 437 and properties.get(566) == varuint(0):
            in_root_instance = True
        if endpoint and ty == 60001:
            properties = {**properties, 60003: varuint(0), 60004: varuint(0), 60005: varuint(1)}
        output.append((ty, properties))
        if ty == 60001:
            for number, (_, key, _, _) in enumerate(PROPERTIES, first_property):
                # TWO_WAY | SOURCE_TO_TARGET_RUNS_FIRST lets a host pause
                # update the bound value without changing its authored default.
                flags = 10 if key == 60016 else 0
                path = varuint(0) + varuint(number)
                output.append((447, {586: varuint(key), 587: varuint(flags),
                                     588: varuint(len(path)) + path}))
    keys = sorted(types)
    data = bytearray(b"RIVE" + b"".join(varuint(v) for v in version))
    data.extend(b"".join(varuint(k) for k in keys) + b"\0")
    for start in range(0, len(keys), 4):
        data.extend(struct.pack("<I", sum(types[k] << (i * 2) for i, k in enumerate(keys[start:start + 4]))))
    for ty, properties in output:
        data.extend(varuint(ty))
        for key, value in properties.items():
            data.extend(varuint(key) + value)
        data.append(0)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", default=Path("fixtures/video"), type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name in ["greeting", "waiting", "list", "endpoint"]:
        original = "greeting" if name == "endpoint" else name
        data = migrate((args.source / f"{original}.nux").read_bytes(), endpoint=name == "endpoint")
        (args.output / f"{name}.nux").write_bytes(data)
    inventory = json.loads((args.source / "endpoint-inventory.json").read_text())
    inventory["screens"] = json.loads((args.source / "inventory.json").read_text())["screens"]
    (args.output / "endpoint-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    (args.output / "endpoint-journey.json").write_bytes((args.source / "greeting-journey.json").read_bytes())


if __name__ == "__main__":
    main()
