#!/usr/bin/env python3
"""Five-MHz qualification prevents a 20-MHz grid from deciding tiny A*T differences."""
import json,subprocess,sys,time
from run_btb_matrix import CONFIGS,NPC,ROOT,TOOL
joint=['TAGE-BT16','TAGE-BT32','TAGE-BT64','TAGE-BT64-base','NSL-BT64','EARLY-BT16','TAGE-EARLY-BT16']
extra=NPC/'docs/research/branch-v3/btb-ablation-extension.json';extra_names=list(json.loads(extra.read_text()))
for name in [*CONFIGS,*joint,*extra_names]:
 point=ROOT/'ppa'/name
 while not (point/'qualified.json').exists():time.sleep(10)
 coarse=json.loads((point/'qualified.json').read_text());best=coarse['mhz'];records=[]
 for mhz in range(best+5,min(best+20,805),5):
  subprocess.run([sys.executable,str(TOOL/'probe_ppa.py'),name,'--mhz',str(mhz)],stdout=subprocess.DEVNULL,check=True)
  result=json.loads((point/f'probe-{mhz}.json').read_text());records.append(result)
  if not result['passed']:break
  best=mhz
 (point/'qualified-btb-fine.json').write_text(json.dumps({**coarse,'mhz':best,'grid_mhz':5,'probes':records},indent=2)+'\n')
 command=[sys.executable,str(TOOL/('run_btb_extended.py' if name in joint else 'run_btb_matrix.py')),'frequency',name,'--mhz',str(best)]
 if name in extra_names:command += ['--matrix',str(extra)]
 subprocess.run(command,check=True)
 print('PASS fine frequency',name,best,flush=True)
