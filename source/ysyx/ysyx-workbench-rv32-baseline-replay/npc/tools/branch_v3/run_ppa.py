#!/usr/bin/env python3
import sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];sys.path.insert(0,str(NPC/'scripts'))
from select_icache_ppa import qualify
from followup_branch import defines
for name,choice in [('B0off',0),('H2',2)]:
 qualify(name,NPC/'result/branch-v3/ppa',cache_config=(1024,4,13,32),extra_make=[v.replace('YSYX_','NPC_',1) for v in defines({})]+[f'NPC_BRANCH_STATIC_POLICY={choice}'])
