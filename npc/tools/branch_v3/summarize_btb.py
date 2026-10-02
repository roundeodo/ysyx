#!/usr/bin/env python3
"""Pair BTB runs by exact image, service, outputs, and frequency; report omissions."""
import collections,hashlib,json,re
from pathlib import Path
from summarize import means
from run_btb_matrix import CONFIGS,NPC,ROOT
from run_btb_extended import CONFIGS as JOINT

def load(name,suffix):
 directory=ROOT/'rtl'/(name+'-'+suffix);index=directory/'index.json'
 if not index.exists():return None
 records={}
 for row in json.loads(index.read_text()):
  log=directory/(row['name']+'.log');raw=log.read_bytes();assert hashlib.sha256(raw).hexdigest()==row['log_sha256']
  text=raw.decode();assert 'PASS proxy' in text
  values={}
  for line in text.splitlines():
   if line.startswith(('RESULT ','COUNTERS ','DETAIL ')):
    values.update(dict(re.findall(r'(\w+)=(\w+)',line)))
  plus=dict(x[1:].split('=',1) for x in row['command'][1:] if x.startswith('+'))
  records[row['name']]={'values':values,'plus':plus,'log':str(log.relative_to(NPC)),'log_sha256':row['log_sha256'],'binary_sha256':row['binary_sha256']}
 return records

def paired(name,suffixes,baseline,baseline_suffixes):
 candidate,reference={},{}
 for suffix in suffixes:
  found=load(name,suffix)
  if found is None:return None
  candidate.update(found)
 for suffix in baseline_suffixes:
  found=load(baseline,suffix)
  if found is None:return None
  reference.update(found)
 assert set(candidate)==set(reference)
 details=[];totals=collections.Counter();base_totals=collections.Counter()
 for case,record in candidate.items():
  ref=reference[case];v,b=record['values'],ref['values'];p,q=record['plus'],ref['plus']
  assert all(p[k]==q[k] for k in ['image','latency_ns','beat_ns','memory_mode','seed','random_stalls'])
  assert all(v[k]==b[k] for k in ['retired','all_retired','digest','checksum'])
  ratio=(int(v['cycles'])/int(p['cpu_mhz']))/(int(b['cycles'])/int(q['cpu_mhz']))
  details.append({'case':case,'family':case.split('-')[0].removesuffix('_stream').removesuffix('_long'),'time_ratio':ratio,'cycles':int(v['cycles']),'baseline_cycles':int(b['cycles']),'mhz':int(p['cpu_mhz']),'baseline_mhz':int(q['cpu_mhz']),'ipc':int(v['retired'])/int(v['cycles']),'i_beats':int(v['i_beats']),'baseline_i_beats':int(b['i_beats']),**{k:record[k] for k in ['log','log_sha256','binary_sha256']}})
  for key in ['cycles','retired','conditional_errors','target_errors','misses','i_beats','d_beats','data_wait','frontend_wait','queries']:
   totals[key]+=int(v[key]);base_totals[key]+=int(b[key])
 return {'name':name,**means(details),'totals':dict(totals),'baseline_totals':dict(base_totals),'details':details}

def main():
 extra={}
 for matrix in ['btb-ablation-extension.json','btb-direction-extension.json',
                'btb-simple-direction-extension.json']:
  extra.update(json.loads((NPC/'docs/research/branch-v3'/matrix).read_text()))
 names=[*CONFIGS,*[n for n in JOINT if not n.endswith('-long')],*extra]
 results=[]
 for name in names:
  row={'name':name,'same_700':paired(name,['dev','streams'],'BT0',['dev','streams']),
       'common_legal_520':paired(name,['dev-520','streams-520'],'BT0',['dev-520','streams-520']),
       'common_legal_400':paired(name,['common-400-dev','common-400-streams'],
                                'BT0',['common-400-dev','common-400-streams'])}
  for mhz in [400,520]:
   probe=ROOT/'ppa'/name/f'probe-{mhz}.json'
   if row[f'common_legal_{mhz}'] is not None:
    assert probe.exists() and json.loads(probe.read_text())['passed'],(name,mhz)
  q=ROOT/'ppa'/name/'qualified.json'
  if q.exists():
   row['ppa']=json.loads(q.read_text());mhz=row['ppa']['mhz'];base_mhz=json.loads((ROOT/'ppa/BT0/qualified.json').read_text())['mhz']
   own=paired(name,[f'dev-{mhz}',f'streams-{mhz}'],'BT0',[f'dev-{base_mhz}',f'streams-{base_mhz}'])
   row['own_legal_frequency']=own
   if own:
    area_base=json.loads((ROOT/'ppa/BT0/qualified.json').read_text())['area_um2']
    row['area_ratio']=row['ppa']['area_um2']/area_base;row['area_time_ratio']=row['area_ratio']*own['paired_geomean']
  fine=ROOT/'ppa'/name/'qualified-btb-fine.json'
  base_fine=ROOT/'ppa/BT0/qualified-btb-fine.json'
  if fine.exists() and base_fine.exists():
   row['ppa_fine']=json.loads(fine.read_text());f=row['ppa_fine']['mhz'];bf=json.loads(base_fine.read_text())['mhz']
   own=paired(name,[f'dev-{f}',f'streams-{f}'],'BT0',[f'dev-{bf}',f'streams-{bf}'])
   row['fine_legal_frequency']=own
   if own:row['fine_area_time_ratio']=row['ppa_fine']['area_um2']/json.loads(base_fine.read_text())['area_um2']*own['paired_geomean']
  results.append(row)
 long=[]
 long_names=[n for n in JOINT if n.endswith('-long')]+['TAGE-BT64','BT16-admit-long','BT16-rrip-all-long']
 for name in long_names:
  row=paired(name,['long'],'BT0-long',['long'])
  if row:long.append(row)
 paired_long=[]
 for name in long_names+['NSL-BT64','TAGE-BT32-fold','NSL-BT32-fold',
                        'B64-BT32-fold','G256-BT32-fold','BT32-fold-long']:
  row=paired(name,['paired-long-700'],'BT0-long',['paired-long-700'])
  if row:paired_long.append(row)
 validation=[];sensitivity=[]
 contract=NPC/'docs/research/branch-v3/btb-validation-contract.json'
 if contract.exists():
  validation_names=json.loads(contract.read_text())['candidates']
  if (NPC/'docs/research/branch-v3/btb-fast-validation-extension.json').exists():
   validation_names+=['NSL-BT64']
  for name in validation_names:
   point=ROOT/'ppa'/name
   qualified_file=next(point/file for file in ['qualified-btb-fine.json','qualified-fine.json','qualified.json'] if (point/file).exists())
   qualified=json.loads(qualified_file.read_text())
   mhz=qualified['mhz'];base_mhz=json.loads((ROOT/'ppa/BT0/qualified-btb-fine.json').read_text())['mhz']
   row=paired(name,[f'validation-{mhz}-dev',f'validation-{mhz}-streams'],
              'BT0',[f'validation-{base_mhz}-dev',f'validation-{base_mhz}-streams'])
   if row:
    row['area_um2']=qualified['area_um2'];row['mhz']=mhz
    row['area_time_ratio']=qualified['area_um2']/json.loads((ROOT/'ppa/BT0/qualified.json').read_text())['area_um2']*row['paired_geomean']
    validation.append(row)
   for label in ['20ns','200ns','random-191','random-811']:
    suffixes=[f'sensitivity-{label}-520-{part}' for part in ['dev','streams']]
    row=paired(name,suffixes,'BT0',suffixes)
    if row:sensitivity.append({'condition':label,**row})
 icache=[]
 for suffix in ['', '-ic8k']:
  row=paired('G256-BT32-fold'+suffix,['dev','streams'],
             'TAGE-BT32-fold'+suffix,['dev','streams'])
  if row:icache.append({'icache_bytes':8192 if suffix else 1024,**row})
 earlier_controls=[]
 for name in ['H2E-victim','R0-victim','NSmallER-victim']:
  point=ROOT/'ppa'/name
  qualified_file=next(point/file for file in ['qualified-fine.json','qualified.json'] if (point/file).exists())
  q=json.loads(qualified_file.read_text());mhz=q['mhz']
  own=paired(name,[f'{mhz}MHz-proxy',f'{mhz}MHz-stream'],
             'BT0',['dev-735','streams-735'])
  row={'name':name,'ppa':q,'same_700':paired(name,['dev','stream-dev-700'],'BT0',['dev','streams']),
       'own_legal_frequency':own}
  if own:row['area_time_ratio']=q['area_um2']/json.loads((ROOT/'ppa/BT0/qualified.json').read_text())['area_um2']*own['paired_geomean']
  earlier_controls.append(row)
 long_legal=[]
 long_contract=NPC/'docs/research/branch-v3/btb-long-qualification-contract.json'
 if long_contract.exists():
  for split in ['development','validation']:
   for name,(ppa,mhz) in json.loads(long_contract.read_text())['points'].items():
    tail='-validation' if split=='validation' else ''
    row=paired(name,[f'paired-long-{mhz}{tail}'],'BT0-long',[f'paired-long-735{tail}'])
    if row:
     row['split']=split;row['mhz']=mhz
     row['area_um2']=json.loads((ROOT/'ppa'/ppa/'qualified.json').read_text())['area_um2']
     row['area_time_ratio']=row['area_um2']/json.loads((ROOT/'ppa/BT0/qualified.json').read_text())['area_um2']*row['paired_geomean']
     long_legal.append(row)
 output={'scope':'development and explicitly labelled validation; no train or final holdout; same 700 MHz is logical diagnostic unless STA passes',
  'comparison':'seven equal-weight short families; extended jsmn/miniz reported separately; common and own frequency rerun physical-ns memory',
  'pending':{'short_700':[r['name'] for r in results if r['same_700'] is None],
             'PPA':[r['name'] for r in results if 'ppa' not in r],
             'own_frequency':[r['name'] for r in results if not r.get('own_legal_frequency')]},
  'results':results,'long':long,'paired_long':paired_long,
  'validation':validation,'sensitivity':sensitivity,'icache_diagnostic':icache,
  'earlier_strong_controls':earlier_controls,
  'long_legal':long_legal,
  'default_changed':False,'final_holdout_used':False}
 (NPC/'docs/research/branch-v3/btb-results.json').write_text(json.dumps(output,indent=2)+'\n')
 for r in results:
  measured=r['same_700'];ppa=r.get('ppa',{});own=r.get('own_legal_frequency')
  if measured:print(r['name'],'700 ratio',round(measured['paired_geomean'],6),'area',ppa.get('area_um2'),'MHz',ppa.get('mhz'),'own',round(own['paired_geomean'],6) if own else 'pending','AT',round(r['area_time_ratio'],6) if own else 'pending')
 print('LONG complete:',[r['name'] for r in long]);print('PENDING',output['pending'])
if __name__=='__main__':main()
