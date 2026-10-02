#!/usr/bin/env python3
"""Frozen BTB main effects and selected combinations, with optional whole-core PPA."""
import argparse,json,subprocess,sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3';TOOL=Path(__file__).resolve().parent
sys.path.insert(0,str(NPC/'scripts'))
from followup_branch import defines
from select_icache_ppa import qualify
CONFIGS={
 'BT0':{}, 'BT32':{'btb':32},'BT64':{'btb':64},'BT128':{'btb':128},
 'BT16-admit':{'target_admission':2},
 'BT16-rrip-all':{'target_policy':2,'target_admission':1},
 'BT16-rrip':{'target_policy':2,'target_admission':2},
 'BT16-fold':{'target_index':2},
 'BT16-way4':{'btb_ways':4},
 'BT16-way4-rrip':{'btb_ways':4,'target_policy':2,'target_admission':2},
 'BT16-select':{'btb_ways':4,'target_index':2,'target_policy':2,'target_admission':2},
 'BT32-select':{'btb':32,'btb_ways':4,'target_index':1,'target_policy':2,'target_admission':2},
 'BT64-select':{'btb':64,'btb_ways':4,'target_index':2,'target_policy':2,'target_admission':2},
}
FLAGS={'btb':'--btb','btb_ways':'--btb-ways','target_policy':'--btb-policy','target_index':'--btb-index','target_admission':'--btb-admission'}
def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['rtl','ppa','frequency']);p.add_argument('names',nargs='+');p.add_argument('--matrix',type=Path);p.add_argument('--resume',action='store_true');p.add_argument('--mhz',type=int,default=700);a=p.parse_args()
 configs=json.loads(a.matrix.read_text()) if a.matrix else CONFIGS
 assert all(name in configs for name in a.names)
 frozen=a.matrix or NPC/'docs/research/branch-v3/btb-matrix.json'
 if frozen.exists():assert json.loads(frozen.read_text())==configs
 else:frozen.write_text(json.dumps(configs,indent=2)+'\n')
 for name in a.names:
  c=configs[name]
  if a.action=='ppa':
   qualify(name,ROOT/'ppa',a.resume,cache_config=(1024,4,13,32),extra_make=[s.replace('YSYX_','NPC_',1) for s in defines(c)])
   continue
  if not (ROOT/'builds'/name/'obj/Vexploration_core_tb').exists():
   command=[sys.executable,str(TOOL/'run_core.py'),'build','--name',name]
   for key,value in c.items():command += [FLAGS[key],str(value)]
   subprocess.run(command,check=True)
  for suffix,images in [('dev',ROOT/'images'),('streams',ROOT/'streams-development')]:
   label=name+'-'+suffix+(f'-{a.mhz}' if a.action=='frequency' else '')
   if (ROOT/'rtl'/label/'index.json').exists():continue
   subprocess.run([sys.executable,str(TOOL/'run_core.py'),'run','--name',name,'--label',label,'--images',str(images),'--compact','--mhz',str(a.mhz)],check=True)
  print('COMPLETE RTL',name,flush=True)
if __name__=='__main__':main()
