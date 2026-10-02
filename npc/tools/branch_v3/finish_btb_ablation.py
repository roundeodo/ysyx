#!/usr/bin/env python3
"""Finish the predeclared extra LRU and index controls after the main mapping queue."""
import json,subprocess,sys,time
from run_btb_matrix import NPC,ROOT,TOOL
matrix=NPC/'docs/research/branch-v3/btb-ablation-extension.json';names=list(json.loads(matrix.read_text()))
while not (ROOT/'ppa/TAGE-EARLY-BT16/qualified.json').exists():time.sleep(10)
subprocess.run([sys.executable,str(TOOL/'run_btb_matrix.py'),'ppa','--matrix',str(matrix),*names],check=True)
for name in names:
 mhz=json.loads((ROOT/'ppa'/name/'qualified.json').read_text())['mhz']
 for frequency in sorted({520,mhz}):
  subprocess.run([sys.executable,str(TOOL/'probe_ppa.py'),name,'--mhz',str(frequency)],check=True)
  assert json.loads((ROOT/'ppa'/name/f'probe-{frequency}.json').read_text())['passed']
  subprocess.run([sys.executable,str(TOOL/'run_btb_matrix.py'),'frequency','--matrix',str(matrix),name,'--mhz',str(frequency)],check=True)
