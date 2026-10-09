"""SDK regression fixture: one-way entry reads env, with a shared Experience root.
Wire keys: runtime c52f4b43c defs/upstream-runtime. No compiler/build dependency.
"""
from pathlib import Path
import hashlib
import json
import struct

SCHEMA = {'Backboard': (23, {}),
 'ViewModel': (435, {'name': (557, 'String'), 'viewModelType': (981, 'uint')}),
 'ViewModelPropertyNumber': (431, {'name': (557, 'String')}),
 'ViewModelPropertyBoolean': (448, {'name': (557, 'String')}),
 'ViewModelPropertyViewModel': (436,
                                {'name': (557, 'String'), 'viewModelReferenceId': (565, 'uint')}),
 'ViewModelInstance': (437, {'name': (4, 'String'), 'viewModelId': (566, 'uint')}),
 'ViewModelInstanceNumber': (442,
                             {'viewModelPropertyId': (554, 'uint'),
                              'propertyValue': (575, 'double')}),
 'ViewModelInstanceBoolean': (449,
                              {'viewModelPropertyId': (554, 'uint'),
                               'propertyValue': (593, 'bool')}),
 'ViewModelInstanceViewModel': (444,
                                {'viewModelPropertyId': (554, 'uint'),
                                 'propertyValue': (577, 'uint')}),
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
 'LinearAnimation': (31, {'name': (55, 'String'), 'fps': (56, 'uint'), 'duration': (57, 'uint')}),
 'KeyedObject': (25, {'objectId': (51, 'uint')}),
 'KeyedProperty': (26, {'propertyKey': (53, 'uint')}),
 'KeyFrameDouble': (30, {'frame': (67, 'uint'), 'value': (70, 'double')}),
 'StateMachine': (53, {'name': (55, 'String')}),
 'StateMachineLayer': (57, {'name': (138, 'String')}),
 'AnyState': (62, {}),
 'EntryState': (63, {}),
 'StateTransition': (65, {'stateToId': (151, 'uint')}),
 'BindablePropertyBoolean': (472, {'propertyValue': (634, 'bool')}),
 'DataBindContext': (447, {'propertyKey': (586, 'uint'), 'sourcePathIds': (588, 'Bytes')}),
 'TransitionViewModelCondition': (482, {'opValue': (650, 'uint')}),
 'TransitionPropertyViewModelComparator': (479, {}),
 'TransitionValueBooleanComparator': (481, {'value': (647, 'bool')}),
 'AnimationState': (61, {'animationId': (149, 'uint')}),
 'ExitState': (64, {})}

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
obj("ViewModel", name="Runtime entry scr_screens_sentry")
obj("ViewModelPropertyViewModel", name="experience", viewModelReferenceId=1)
obj("ViewModel", name="Experience")
obj("ViewModelPropertyNumber", name="answer")
obj("ViewModel", name="env", viewModelType=2)
obj("ViewModelPropertyBoolean", name="reduceMotion")
obj("ViewModelPropertyViewModel", name="safeArea", viewModelReferenceId=3)
obj("ViewModel", name="env.safeArea")
for edge in ["top", "bottom", "left", "right"]:
    obj("ViewModelPropertyNumber", name=edge)
# Each model has one authored instance, at its schema-local index 0.
obj("ViewModelInstance", name="experience", viewModelId=1)
obj("ViewModelInstanceNumber", viewModelPropertyId=0, propertyValue=0.0)
obj("ViewModelInstance", name="insets", viewModelId=3)
for index in range(4):
    obj("ViewModelInstanceNumber", viewModelPropertyId=index, propertyValue=0.0)
obj("ViewModelInstance", name="env", viewModelId=2)
obj("ViewModelInstanceBoolean", viewModelPropertyId=0, propertyValue=False)
obj("ViewModelInstanceViewModel", viewModelPropertyId=1, propertyValue=0)
obj("ViewModelInstance", name="entry-root", viewModelId=0)
obj("ViewModelInstanceViewModel", viewModelPropertyId=0, propertyValue=0)
obj("Artboard", name="entry", width=393.0, height=852.0, viewModelId=0, defaultStateMachineId=0)
obj("Shape", name="state marker", parentId=0, x=20.0, y=40.0)
obj("Rectangle", parentId=1, width=20.0, height=20.0)
obj("Fill", parentId=1)
obj("SolidColor", parentId=3, colorValue=0xff000000)
for name, x in [("motion", 20.0), ("still", 80.0)]:
    obj("LinearAnimation", name=name, fps=60, duration=60)
    obj("KeyedObject", objectId=1)
    obj("KeyedProperty", propertyKey=SCHEMA["Shape"][1]["x"][0])
    obj("KeyFrameDouble", frame=0, value=x)
obj("StateMachine", name="Entry choice")
obj("StateMachineLayer", name="one way")
obj("AnyState")
obj("EntryState")
obj("StateTransition", stateToId=3)
obj("BindablePropertyBoolean", propertyValue=False)
obj("DataBindContext", propertyKey=SCHEMA["BindablePropertyBoolean"][1]["propertyValue"][0], sourcePathIds=[2, 0])
obj("TransitionViewModelCondition", opValue=0)
obj("TransitionPropertyViewModelComparator")
obj("TransitionValueBooleanComparator", value=True)
# Total boolean choice: motion is the fallback when reduceMotion is not true.
obj("StateTransition", stateToId=2)
obj("AnimationState", animationId=0)
obj("AnimationState", animationId=1)
obj("ExitState")
root = Path(__file__).parent
(root / "screen.riv").write_bytes(scene)
(root / "provenance.json").write_text(json.dumps({
    "fonts": [], "authorship": "SDK-authored entry-state regression; generate.py",
    "wireSource": "nuxie-runtime c52f4b43c defs/upstream-runtime",
    "sha256": hashlib.sha256(scene).hexdigest(),
    "expected": {"reduceMotionFalse": "motion: black marker at (20,40)",
                 "reduceMotionTrue": "still: black marker at (80,40)",
                 "laterChanges": "no return to entry"}
}, indent=2) + "\n")
