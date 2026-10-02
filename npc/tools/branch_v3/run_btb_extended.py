#!/usr/bin/env python3
"""Joint direction/target candidates and larger, independently frozen request streams."""
import argparse,json,subprocess,sys
from pathlib import Path
from run_btb_matrix import CONFIGS as TARGETS,FLAGS as TARGET_FLAGS,NPC,ROOT,TOOL
from followup_branch import defines
from select_icache_ppa import qualify
CONFIGS={
 'BT0-long':{},
 'BT16-select-long':TARGETS['BT16-select'],
 'BT32-select-long':TARGETS['BT32-select'],
 'BT64-select-long':TARGETS['BT64-select'],
 'TAGE-long':{'direction_policy':5},
 'TAGE-BT16':{**TARGETS['BT16-select'],'direction_policy':5},
 'TAGE-BT32':{**TARGETS['BT32-select'],'direction_policy':5},
 'TAGE-BT64':{**TARGETS['BT64-select'],'direction_policy':5},
 'TAGE-BT64-base':{'btb':64,'direction_policy':5},
 'NSL-BT64':{**TARGETS['BT64-select'],'direction_policy':5,'sc':1,'loop':1},
 'EARLY-BT16':{**TARGETS['BT16-select'],'early':1},
 'TAGE-EARLY-BT16':{**TARGETS['BT16-select'],'direction_policy':5,'early':1},
}
FLAGS={**TARGET_FLAGS,'bht':'--bht','history_bits':'--history','direction_policy':'--direction','sc':'--sc','loop':'--loop','early':'--early'}
def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['rtl','ppa','long','frequency']);p.add_argument('names',nargs='+');p.add_argument('--matrix',type=Path);p.add_argument('--resume',action='store_true');p.add_argument('--mhz',type=int,default=700);a=p.parse_args()
 configs=json.loads(a.matrix.read_text()) if a.matrix else CONFIGS
 assert all(name in configs for name in a.names)
 frozen=a.matrix or NPC/'docs/research/branch-v3/btb-joint-matrix.json'
 if frozen.exists():assert json.loads(frozen.read_text())==configs
 else:frozen.write_text(json.dumps(configs,indent=2)+'\n')
 for name in a.names:
  c=configs[name]
  if a.action=='ppa':
   settings=defines(c)+[f'YSYX_BRANCH_SC_ENABLE={c.get("sc",0)}',f'YSYX_BRANCH_LOOP_ENABLE={c.get("loop",0)}',f'YSYX_BRANCH_EARLY_TARGET={c.get("early",0)}']
   qualify(name,ROOT/'ppa',a.resume,cache_config=(1024,4,13,32),extra_make=[s.replace('YSYX_','NPC_',1) for s in settings]);continue
  if not (ROOT/'builds'/name/'obj/Vexploration_core_tb').exists():
   command=[sys.executable,str(TOOL/'run_core.py'),'build','--name',name,'--ram-kib','2048']
   for key,value in c.items():command += [FLAGS[key],str(value)]
   subprocess.run(command,check=True)
  datasets=[('dev',ROOT/'images'),('streams',ROOT/'streams-development')]
  if a.action=='long':datasets=[('long',ROOT/'streams-long-development')]
  for suffix,images in datasets:
   label=name+'-'+suffix+(f'-{a.mhz}' if a.action=='frequency' or a.mhz!=700 else '')
   if (ROOT/'rtl'/label/'index.json').exists():continue
   command=[sys.executable,str(TOOL/'run_core.py'),'run','--name',name,'--label',label,'--images',str(images),'--compact','--mhz',str(a.mhz),'--max-cycles','200000000']
   command += ['--branch-window','8192']
   subprocess.run(command,check=True)
  print('COMPLETE',a.action,name,a.mhz,flush=True)
if __name__=='__main__':main()
