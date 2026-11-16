#!/usr/bin/env python3
"""Freeze upstream inputs without accessing the final holdout."""
import hashlib,json,urllib.request,subprocess
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];root=NPC/'result/branch-v3/upstream';root.mkdir(parents=True,exist_ok=True)
def get(url):
    return subprocess.check_output(['curl','--fail','--location','--retry','3','--connect-timeout','15','--max-time','60',url])
frozen=NPC/'tests/branch_v3/upstream-manifest.json'
if frozen.exists():
    records=json.loads(frozen.read_text())
    for record in records:
        data=get(record['url']);assert hashlib.sha256(data).hexdigest()==record['sha256']
        name=record['name']+'.json' if record['name'] in ('gpt2','bert') else record['name']
        (root/name).write_bytes(data)
    (root/'manifest.json').write_text(json.dumps(records,indent=2)+'\n')
    vocabulary=json.loads((NPC/'tests/branch_v3/stream-inputs.json').read_text())
    data=get(vocabulary['url']);assert hashlib.sha256(data).hexdigest()==vocabulary['sha256']
    (root/'gpt2-vocab.json').write_bytes(data)
    print('Fetched hash-checked frozen inputs')
    raise SystemExit(0)
records=[]
for name,repo in [('gpt2','openai-community/gpt2'),('bert','google-bert/bert-base-uncased')]:
    meta=json.loads(get('https://huggingface.co/api/models/'+repo));commit=meta['sha']
    url=f'https://huggingface.co/{repo}/resolve/{commit}/config.json';data=get(url)
    (root/(name+'.json')).write_bytes(data)
    records.append({'name':name,'split':'development','repository':repo,'commit':commit,'url':url,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'license':meta.get('cardData',{}).get('license')})
commit=json.loads(get('https://api.github.com/repos/zserge/jsmn/commits/master'))['sha']
for name in ['jsmn.h','LICENSE']:
    url=f'https://raw.githubusercontent.com/zserge/jsmn/{commit}/{name}';data=get(url);(root/name).write_bytes(data)
    records.append({'name':name,'repository':'zserge/jsmn','commit':commit,'url':url,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'license':'MIT'})
(root/'manifest.json').write_text(json.dumps(records,indent=2)+'\n')
print('Frozen',len(records),'upstream artifacts; holdout not fetched')
