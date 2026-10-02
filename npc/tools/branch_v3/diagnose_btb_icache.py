#!/usr/bin/env python3
"""Separate I-cache interaction from direction accuracy; never a default candidate."""
import json,subprocess,sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3';TOOL=Path(__file__).resolve().parent
record={'scope':'diagnostic only, not part of main selection or a PPA claim','change':'I-cache 1KiB to 8KiB; ways4/line32/policy13, D-cache and fixed-ns memory unchanged','purpose':'test whether fewer EX corrections imply fewer cycles when the main instruction footprint fits better','candidates':['TAGE-BT32-fold','G256-BT32-fold']}
(NPC/'docs/research/branch-v3/btb-icache-diagnostic.json').write_text(json.dumps(record,indent=2)+'\n')
for base in record['candidates']:
 name=base+'-ic8k'
 command=[sys.executable,str(TOOL/'run_core.py'),'build','--name',name,'--ram-kib','2048','--icache-bytes','8192','--btb','32','--btb-ways','4','--btb-index','2','--btb-policy','2','--btb-admission','2']
 command += ['--direction','5'] if base.startswith('TAGE') else ['--direction','1','--bht','256','--history','4']
 if not (ROOT/'builds'/name/'obj/Vexploration_core_tb').exists():subprocess.run(command,check=True)
 for suffix,images in [('dev','images'),('streams','streams-development')]:
  label=name+'-'+suffix
  if (ROOT/'rtl'/label/'index.json').exists():continue
  subprocess.run([sys.executable,str(TOOL/'run_core.py'),'run','--name',name,'--label',label,'--images',str(ROOT/images),'--compact','--branch-window','8192'],check=True)
 print('COMPLETE controlled I-cache diagnostic',name,flush=True)
