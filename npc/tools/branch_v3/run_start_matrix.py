#!/usr/bin/env python3
import subprocess
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];root=NPC/'result/branch-v3'
for name,extra in [('B0off',[]),('S',['--choice','1']),('B32',['--btb','32']),('T16',['--direction','4']),('T16B32',['--direction','4','--btb','32'])]:
 for action in ['build','run']:
  command=['python3',str(NPC/'tools/branch_v3/run_core.py'),action,'--name',name,*extra]
  with (root/(action+'-'+name+'.log')).open('w') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
  print('PASS',action,name,flush=True)
