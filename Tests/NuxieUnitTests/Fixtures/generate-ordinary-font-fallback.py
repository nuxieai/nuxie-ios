from pathlib import Path
import json,struct,hashlib
# Recorded Rive-native keys from runtime42b4fdcd1. This generator needs no
# runtime checkout or platform font. Literal strings and positions are fixture
# inputs, not calculated from rendering output.
TYPES = {'Backboard': 23, 'FontAsset': 141, 'Artboard': 1, 'Text': 134, 'TextStylePaint': 137, 'Fill': 20, 'SolidColor': 18, 'TextValueRun': 135}
PROPERTIES = {'Component': {'parentId': 5, 'name': 4}, 'FileAsset': {'assetId': 204}, 'Asset': {'name': 203}, 'Artboard': {'width': 7, 'height': 8}, 'Node': {'x': 13, 'y': 14}, 'TextStyle': {'fontAssetId': 279, 'fontSize': 274}, 'SolidColor': {'colorValue': 37}, 'TextValueRun': {'styleId': 272, 'text': 268}}
def prop(name,key):return PROPERTIES[name][key]
b=bytearray(b'RIVE')
def var(v):
 while v>=128:b.append((v&127)|128);v>>=7
 b.append(v)
def field(kind,key,value):
 var(prop(kind,key))
 if isinstance(value,float):b.extend(struct.pack('<f',value))
 elif isinstance(value,str):raw=value.encode();var(len(raw));b.extend(raw)
 elif kind=='SolidColor' and key=='colorValue':b.extend(struct.pack('<I',value))
 elif isinstance(value,int):var(value)
def obj(name,fields):
 var(TYPES[name])
 for kind,key,value in fields:field(kind,key,value)
 var(0)
for v in [7,0,9641,0]:var(v)
obj('Backboard',[])
obj('FontAsset',[('FileAsset','assetId',7),('Asset','name','P038 primary')])
obj('Artboard',[('Component','name','P038 ordinary text'),('Artboard','width',390.0),('Artboard','height',844.0)])
rows=[('Japanese','日本語'),('Arabic','مرحبا'),('Hebrew','שלום'),('Hindi','नमस्ते'),('emoji','😀'),('missing','\U0010ffff'),('Latin','Ada')]
for i,(name,value) in enumerate(rows):
 idx=1+i*5; y=32.0+i*108.0
 obj('Text',[('Component','parentId',0),('Component','name',name),('Node','x',24.0),('Node','y',y)])
 obj('TextStylePaint',[('Component','parentId',idx),('TextStyle','fontAssetId',0),('TextStyle','fontSize',64.0)])
 obj('Fill',[('Component','parentId',idx+1)])
 obj('SolidColor',[('Component','parentId',idx+2),('SolidColor','colorValue',0xfff8f1dc)])
 obj('TextValueRun',[('Component','parentId',idx),('Component','name',name+' value'),('TextValueRun','styleId',idx+1),('TextValueRun','text',value)])
p=Path(__file__).with_name('ordinary_font_fallback.riv');p.write_bytes(b)
(p.parent/'ordinary_font_fallback.provenance.json').write_text(json.dumps({'generator':'generate-ordinary-font-fallback.py','schemaPin':'42b4fdcd1','sha256':hashlib.sha256(b).hexdigest(),'width':390,'height':844,'fontSize':64,'rows':[{'name':n,'text':v,'x':24,'y':32+i*108} for i,(n,v) in enumerate(rows)],'externalPrimary':'Chosen by the SDK test: current System or Latin-only Roboto. No fallback attached.','nativeStructure':'Ordinary Text and TextValueRun; no TextInput or host editing overlay'},ensure_ascii=False,indent=2)+'\n')
print(len(b),hashlib.sha256(b).hexdigest())
