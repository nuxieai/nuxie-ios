"""SDK regression fixture: a color bound to the `Theme` global, with `env.colorScheme`.
File names are distinct from env-entry's because SwiftPM flattens processed test resources.
Wire keys: runtime a237fc817 defs/upstream-runtime. No compiler/build dependency.
"""
from pathlib import Path
import hashlib
import json
import struct

SCHEMA = {'Backboard': (23, {}),
 'DataEnumCustom': (438, {'name': (572, 'String')}),
 'DataEnumValue': (445, {'key': (578, 'String'), 'value': (579, 'String')}),
 'ViewModel': (435, {'name': (557, 'String'), 'viewModelType': (981, 'uint')}),
 'ViewModelPropertyEnumCustom': (439, {'name': (557, 'String'), 'enumId': (574, 'uint')}),
 'ViewModelPropertyColor': (440, {'name': (557, 'String')}),
 'ViewModelInstance': (437, {'name': (4, 'String'), 'viewModelId': (566, 'uint')}),
 'ViewModelInstanceEnum': (432,
                           {'viewModelPropertyId': (554, 'uint'),
                            'propertyValue': (560, 'uint')}),
 'ViewModelInstanceColor': (426,
                            {'viewModelPropertyId': (554, 'uint'),
                             'propertyValue': (555, 'Color')}),
 'Artboard': (1,
              {'name': (4, 'String'),
               'width': (7, 'double'),
               'height': (8, 'double'),
               'defaultStateMachineId': (236, 'uint'),
               'viewModelId': (583, 'uint')}),
 'Shape': (3,
           {'name': (4, 'String'),
            'parentId': (5, 'uint'),
            'x': (13, 'double'),
            'y': (14, 'double')}),
 'Rectangle': (7, {'parentId': (5, 'uint'), 'width': (20, 'double'), 'height': (21, 'double')}),
 'Fill': (20, {'parentId': (5, 'uint')}),
 'SolidColor': (18, {'parentId': (5, 'uint'), 'colorValue': (37, 'Color')}),
 'DataBindContext': (447, {'propertyKey': (586, 'uint'), 'sourcePathIds': (588, 'Bytes')}),
 'StateMachine': (53, {'name': (55, 'String')}),
 'StateMachineLayer': (57, {'name': (138, 'String')}),
 'AnyState': (62, {}),
 'EntryState': (63, {}),
 'ExitState': (64, {})}

GLOBAL = 2
LIGHT_SURFACE = 0xFFF2F2F7
DARK_SURFACE = 0xFF1C1C1E
UNBOUND_FILL = 0xFF00FF00

def uint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)

scene = bytearray(b"RIVE" + b"".join(uint(n) for n in [7, 0, 9658, 0]))
def obj(class_name, **properties):
    kind, fields = SCHEMA[class_name]
    scene.extend(uint(kind))
    for name, value in properties.items():
        key, kind = fields[name]
        scene.extend(uint(key))
        if kind in ("uint", "Id", "bool"):
            scene.extend(uint(value))
        elif kind in ("double", "float"):
            scene.extend(struct.pack("<f", value))
        elif kind == "Color":
            scene.extend(struct.pack("<I", value))
        else:
            value = value.encode() if isinstance(value, str) else bytes(value)
            scene.extend(uint(len(value)) + value)
    scene.append(0)

obj("Backboard")
# Enums resolve by file order, so the env enum precedes the property that names it.
obj("DataEnumCustom", name="env.colorScheme")
for label in ["light", "dark"]:
    obj("DataEnumValue", key=label, value=label)
obj("ViewModel", name="Runtime theme scr_screens_stheme")
obj("ViewModel", name="env", viewModelType=GLOBAL)
obj("ViewModelPropertyEnumCustom", name="colorScheme", enumId=0)
obj("ViewModel", name="Theme", viewModelType=GLOBAL)
obj("ViewModelPropertyColor", name="surface")
obj("ViewModelInstance", name="theme-root", viewModelId=0)
obj("ViewModelInstance", name="env", viewModelId=1)
obj("ViewModelInstanceEnum", viewModelPropertyId=0, propertyValue=0)
# The contract's authored order: `light` is the first instance and the default.
obj("ViewModelInstance", name="light", viewModelId=2)
obj("ViewModelInstanceColor", viewModelPropertyId=0, propertyValue=LIGHT_SURFACE)
obj("ViewModelInstance", name="dark", viewModelId=2)
obj("ViewModelInstanceColor", viewModelPropertyId=0, propertyValue=DARK_SURFACE)
obj("Artboard", name="theme", width=393.0, height=852.0, viewModelId=0, defaultStateMachineId=0)
obj("Shape", name="surface", parentId=0, x=100.0, y=100.0)
obj("Rectangle", parentId=1, width=100.0, height=100.0)
obj("Fill", parentId=1)
obj("SolidColor", parentId=3, colorValue=UNBOUND_FILL)
# Binds the fill to Theme.surface: view model 2, property 0.
obj("DataBindContext", propertyKey=SCHEMA["SolidColor"][1]["colorValue"][0], sourcePathIds=[2, 0])
obj("StateMachine", name="Theme")
obj("StateMachineLayer", name="idle")
obj("AnyState")
obj("EntryState")
obj("ExitState")
root = Path(__file__).parent
(root / "theme.riv").write_bytes(scene)
(root / "theme-provenance.json").write_text(json.dumps({
    "fonts": [], "authorship": "SDK-authored dark mode regression; generate-theme.py",
    "wireSource": "nuxie-runtime a237fc817 defs/upstream-runtime",
    "sha256": hashlib.sha256(scene).hexdigest(),
    "expected": {"light": "Theme.light surface 0xFFF2F2F7 at (100,100)",
                 "dark": "Theme.dark surface 0xFF1C1C1E at (100,100)",
                 "lostBinding": "green 0xFF00FF00 fill"}
}, indent=2) + "\n")
