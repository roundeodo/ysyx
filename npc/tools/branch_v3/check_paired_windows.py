#!/usr/bin/env python3
"""Prove that choosing a passive cold/warm start did not change execution."""
import hashlib,json,re
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3';records=[]
indices=set((ROOT/'rtl').glob('*-paired-long-*/index.json'))
indices.update((ROOT/'rtl').glob('*-final-*MHz-streams-long-paired-final/index.json'))
for index in sorted(indices):
 rows={r['name']:r for r in json.loads(index.read_text())}
 for kind in ('jsmn','miniz'):
  a,b=[rows[f'{kind}_long-128-{window}'] for window in ('cold','warm')]
  plus=lambda r:dict(x[1:].split('=',1) for x in r['command'][1:] if x.startswith('+'))
  ia,ib=[Path(plus(r)['image']) for r in (a,b)]
  assert ia.read_bytes()==ib.read_bytes(), 'Cold/warm loaded different machine code'
  def values(r):
   p=index.parent/(r['name']+'.log');raw=p.read_bytes();assert hashlib.sha256(raw).hexdigest()==r['log_sha256']
   line=next(x for x in raw.decode().splitlines() if x.startswith('RESULT '))
   return dict(re.findall(r'(\w+)=(\w+)',line))
  va,vb=values(a),values(b)
  for key in ('total_cycles','all_retired','digest','checksum'):assert va[key]==vb[key],(index,kind,key)
  records.append({'run':index.parent.name,'workload':kind,'same_loaded_hex_sha256':hashlib.sha256(ia.read_bytes()).hexdigest(),
                  'identical_full_execution':{k:va[k] for k in ('total_cycles','all_retired','digest','checksum')},'cold_cycles':int(va['cycles']),'warm_cycles':int(vb['cycles'])})
assert records
(NPC/'docs/research/branch-v3/paired-window-equivalence.json').write_text(json.dumps({'passed':True,'records':records},indent=2)+'\n')
print('PASS same-binary passive windows',len(records),'pairs')
