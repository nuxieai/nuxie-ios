"""SDK-authored native policy fixture. No publisher or runtime build needed."""
from pathlib import Path
import hashlib
import json
import struct

# Wire keys from nuxie-runtime defs/upstream-runtime, also used by env-entry.
SCHEMA = {
    'Backboard': (23, {}),
    'ViewModel': (435, {'name': (557, 's')}),
    'StringProperty': (443, {'name': (557, 's')}),
    'BooleanProperty': (448, {'name': (557, 's')}),
    'ListProperty': (434, {'name': (557, 's')}),
    'ReferenceProperty': (436, {'name': (557, 's'), 'model': (565, 'u')}),
    'Instance': (437, {'name': (4, 's'), 'model': (566, 'u')}),
    'String': (433, {'property': (554, 'u'), 'value': (561, 's')}),
    'Boolean': (449, {'property': (554, 'u'), 'value': (593, 'u')}),
    'Reference': (444, {'property': (554, 'u'), 'value': (577, 'u')}),
    'List': (441, {'property': (554, 'u')}),
    'Artboard': (1, {'name': (4, 's'), 'width': (7, 'f'), 'height': (8, 'f'), 'model': (583, 'u')}),
}

def uint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)

scene = bytearray(b'RIVE' + b''.join(uint(n) for n in [7, 0, 9658, 0]))
def obj(kind, **properties):
    type_id, fields = SCHEMA[kind]
    scene.extend(uint(type_id))
    for name, value in properties.items():
        key, format = fields[name]
        scene.extend(uint(key))
        if format == 's':
            value = value.encode()
            scene.extend(uint(len(value)) + value)
        elif format == 'f':
            scene.extend(struct.pack('<f', value))
        else:
            scene.extend(uint(value))
    scene.append(0)

obj('Backboard')
obj('ViewModel', name='Experience')
obj('ReferenceProperty', name='responses:profile', model=1)
obj('ViewModel', name='Responses:profile')
obj('StringProperty', name='email')
obj('StringProperty', name='name')
obj('BooleanProperty', name='valid')
obj('ReferenceProperty', name='errors', model=2)
obj('ViewModel', name='Errors:profile')
obj('ListProperty', name='email')
obj('ListProperty', name='name')
obj('ViewModel', name='ResponseError')
obj('StringProperty', name='rule')
obj('StringProperty', name='message')
obj('Instance', name='error', model=3)
obj('String', property=0, value='')
obj('String', property=1, value='')
obj('Instance', name='errors', model=2)
obj('List', property=0)
obj('List', property=1)
obj('Instance', name='profile', model=1)
obj('String', property=0, value='')
obj('String', property=1, value='')
obj('Boolean', property=2, value=False)
obj('Reference', property=3, value=0)
obj('Instance', name='experience', model=0)
obj('Reference', property=0, value=0)
obj('Artboard', name='form', width=393.0, height=852.0, model=0)
root = Path(__file__).parent
(root / 'screen.riv').write_bytes(scene)
(root / 'provenance.json').write_text(json.dumps({
    'authorship': 'SDK-authored native group installation regression; generate.py',
    'wireSource': 'nuxie-runtime defs/upstream-runtime ViewModel and instance wire keys',
    'sha256': hashlib.sha256(scene).hexdigest(), 'sizeBytes': len(scene),
    'fonts': []
}, indent=2) + '\n')
