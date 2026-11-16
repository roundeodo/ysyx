#!/usr/bin/env python3
"""Extend the long shortlist with the two inexpensive candidates identified by PPA."""
import argparse,json,subprocess,sys
from pathlib import Path
from run_btb_matrix import NPC,ROOT,TOOL
CONFIGS={'BT16-admit-long':{'target_admission':2},'BT16-rrip-all-long':{'target_admission':1,'target_policy':2}}
p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare','long']);p.add_argument('names',nargs='+',choices=CONFIGS);a=p.parse_args()
frozen=NPC/'docs/research/branch-v3/btb-balanced-extension.json'
record={'reason':'Lowest measured area (taken admission) and low-cost 740 MHz SRRIP-all candidate; identified on development PPA before any of their long results. Workloads/partitions unchanged.','candidates':CONFIGS}
if frozen.exists():assert json.loads(frozen.read_text())==record
else:frozen.write_text(json.dumps(record,indent=2)+'\n')
for name in a.names:
 c=CONFIGS[name]
 if a.action=='prepare':
  command=[sys.executable,str(TOOL/'run_core.py'),'build','--name',name,'--ram-kib','2048','--btb-admission',str(c['target_admission']),'--btb-policy',str(c.get('target_policy',0))]
  if not (ROOT/'builds'/name/'obj/Vexploration_core_tb').exists():subprocess.run(command,check=True)
  datasets=[('dev','images'),('streams','streams-development')]
 else:datasets=[('long','streams-long-development')]
 for suffix,images in datasets:
  label=name+'-'+suffix
  if (ROOT/'rtl'/label/'index.json').exists():continue
  subprocess.run([sys.executable,str(TOOL/'run_core.py'),'run','--name',name,'--label',label,'--images',str(ROOT/images),'--compact','--max-cycles','200000000','--branch-window','8192'],check=True)
 print('COMPLETE',a.action,name,flush=True)
