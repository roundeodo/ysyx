#!/usr/bin/env python3
import argparse,sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];sys.path.insert(0,str(NPC/'scripts'))
from select_icache_ppa import qualify
from followup_branch import defines
configs={'SE0':(0,0,0,1,1),'R0-held':(0,0,0,0,0),'G256':(1,0,0,0,0),'NBase128':(5,0,0,0,0),'S':(0,0,0,0,1),'B64':(0,0,0,0,0),'G64':(1,0,0,0,0),'NSmall':(5,0,0,0,0),'NSmallER':(5,0,0,1,0),'R0':(0,0,0,0,0),'ER0':(0,0,0,1,0),'NER0':(5,0,0,1,0),'B0-current':(0,0,0,0,0),'H2-narrow':(0,0,0,0,2),'H2E-narrow':(0,0,0,1,2),'E0':(0,0,0,1,0),'N0':(5,0,0,0,0),'N0-widthfix':(5,0,0,0,0),'NL':(5,0,1,0,0),'NS':(5,1,0,0,0),'NSL':(5,1,1,0,0),'N0E':(5,0,0,1,0),'B32':(0,0,0,0,0)}
p=argparse.ArgumentParser();p.add_argument('names',nargs='+',choices=configs);p.add_argument('--resume',action='store_true');a=p.parse_args()
for name in a.names:
 direction,sc,loop,early,choice=configs[name]
 settings=defines({'direction_policy':direction,'btb':32 if name=='B32' else 16,'bht':256 if name=='G256' else 64 if name in ('B64','G64') else 16})
 settings += [f'YSYX_BRANCH_EARLY_RAS={int(name in ("R0","R0-held","ER0","NER0","NSmallER"))}',f'YSYX_BRANCH_SC_ENABLE={sc}',f'YSYX_BRANCH_LOOP_ENABLE={loop}',f'YSYX_BRANCH_EARLY_TARGET={early}',f'YSYX_BRANCH_STATIC_POLICY={choice}']
 if name=='NBase128':settings += ['YSYX_BRANCH_TAGE_BASE_ENTRIES=128']
 if name.startswith('NSmall'):settings += ['YSYX_BRANCH_TAGE_BASE_ENTRIES=16','YSYX_BRANCH_TAGE_TAGGED_ENTRIES=8','YSYX_BRANCH_TAGE_TAG_BITS=6','YSYX_BRANCH_TAGE_TABLE_COUNT=2','YSYX_BRANCH_TAGE_HISTORY_BITS_0=3','YSYX_BRANCH_TAGE_HISTORY_BITS_1=7']
 qualify(name,NPC/'result/branch-v3/ppa',a.resume,cache_config=(1024,4,13,32),extra_make=[s.replace('YSYX_','NPC_',1) for s in settings])
