#!/usr/bin/env python3
"""Map the direction ablation on the improved 32-entry target organization."""
import argparse,json,subprocess,sys,time
from pathlib import Path
from run_btb_matrix import NPC,ROOT,TOOL
parser=argparse.ArgumentParser();parser.add_argument('--matrix',type=Path,default=NPC/'docs/research/branch-v3/btb-direction-extension.json');parser.add_argument('--after',default='BT64-select-linear');args=parser.parse_args()
matrix=args.matrix;names=list(json.loads(matrix.read_text()))
while not (ROOT/'ppa'/args.after/'qualified.json').exists():time.sleep(10)
for name in names:
 subprocess.run([sys.executable,str(TOOL/'run_btb_extended.py'),'ppa','--resume','--matrix',str(matrix),name],check=True)
 point=ROOT/'ppa'/name;coarse=json.loads((point/'qualified.json').read_text());best=coarse['mhz'];records=[]
 for mhz in range(best+5,min(best+20,805),5):
  subprocess.run([sys.executable,str(TOOL/'probe_ppa.py'),name,'--mhz',str(mhz)],check=True)
  result=json.loads((point/f'probe-{mhz}.json').read_text());records.append(result)
  if not result['passed']:break
  best=mhz
 (point/'qualified-btb-fine.json').write_text(json.dumps({**coarse,'mhz':best,'grid_mhz':5,'probes':records},indent=2)+'\n')
 for mhz in sorted({400,520,coarse['mhz'],best}):
  subprocess.run([sys.executable,str(TOOL/'probe_ppa.py'),name,'--mhz',str(mhz)],check=True)
  if not json.loads((point/f'probe-{mhz}.json').read_text())['passed']:
   print('UNQUALIFIED frequency; preserve probe, skip performance',name,mhz,flush=True)
   continue
  subprocess.run([sys.executable,str(TOOL/'run_btb_extended.py'),'frequency','--matrix',str(matrix),name,'--mhz',str(mhz)],check=True)
