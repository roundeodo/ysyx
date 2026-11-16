#!/usr/bin/env python3
"""Measure common legal 520 MHz and each measured grid-qualified frequency."""
import json,subprocess,sys,time
from pathlib import Path
from run_btb_matrix import CONFIGS as SIMPLE,NPC,ROOT,TOOL
from run_btb_extended import CONFIGS as JOINT

def wait_for(path):
 while not path.exists():time.sleep(10)
def run(script,*args):subprocess.run([sys.executable,str(TOOL/script),*args],check=True)
for name in [*SIMPLE,'TAGE-BT16','TAGE-BT32','TAGE-BT64','TAGE-BT64-base','NSL-BT64','EARLY-BT16','TAGE-EARLY-BT16']:
 q=ROOT/'ppa'/name/'qualified.json';wait_for(q)
 runner='run_btb_matrix.py' if name in SIMPLE else 'run_btb_extended.py'
 qualified=json.loads(q.read_text())['mhz']
 for mhz in sorted({520,qualified}):
  run('probe_ppa.py',name,'--mhz',str(mhz))
  assert json.loads((q.parent/f'probe-{mhz}.json').read_text())['passed'],(name,mhz)
  run(runner,'frequency',name,'--mhz',str(mhz))
 print('COMPLETE actual frequency comparison',name,qualified,flush=True)
