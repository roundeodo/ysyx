#!/usr/bin/env python3
"""Reuse the repository NEMU comparison, adding explicit V3 hardware switches."""
import json,sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];sys.path.insert(0,str(NPC/'scripts'))
import verify_direction_difftest as suite
from followup_branch import defines
root=NPC/'result/branch-v3/isa';root.mkdir(exist_ok=True)
configs={'NSL-victim':{'direction_policy':5,'sc':1,'loop':1},'B0-victim':{},'NSL-provider':{'direction_policy':5,'sc':1,'loop':1},'H2E-narrow':{'choice':2,'early':1},'R0-held':{'ras':1},'NSmallER-held':{'direction_policy':5,'ras':1,'early':1,'small':1},'N0-spec-final':{'direction_policy':5,'spec':1},'NSmallER':{'direction_policy':5,'ras':1,'early':1,'small':1},'R0':{'ras':1},'ER0':{'ras':1,'early':1},'NER0':{'direction_policy':5,'ras':1,'early':1},'B0-current':{},'E0':{'early':1},'NSL':{'direction_policy':5,'sc':1,'loop':1},'N0-spec':{'direction_policy':5,'spec':1}}
from run_btb_matrix import CONFIGS as BTB_CONFIGS
configs.update(BTB_CONFIGS)
from run_btb_extended import CONFIGS as JOINT_CONFIGS
configs.update(JOINT_CONFIGS)
configs['H2E-victim']={'choice':2,'early':1}
for matrix in ['btb-ablation-extension.json', 'btb-direction-extension.json',
               'btb-simple-direction-extension.json', 'btb-replacement-rtl-matrix.json']:
    configs.update(json.loads((NPC/'docs/research/branch-v3'/matrix).read_text()))
(root/'configurations.json').write_text(json.dumps(configs,indent=2)+'\n')
def v3_defines(c):
    geometry=['YSYX_BRANCH_TAGE_BASE_ENTRIES=16','YSYX_BRANCH_TAGE_TAGGED_ENTRIES=8','YSYX_BRANCH_TAGE_TAG_BITS=6','YSYX_BRANCH_TAGE_TABLE_COUNT=2'] if c.get('small') else []
    return defines(c)+geometry+[f'YSYX_BRANCH_STATIC_POLICY={c.get("choice",0)}',f'YSYX_BRANCH_EARLY_RAS={c.get("ras",0)}',f'YSYX_BRANCH_EARLY_TARGET={c.get("early",0)}',f'YSYX_BRANCH_SC_ENABLE={c.get("sc",0)}',f'YSYX_BRANCH_LOOP_ENABLE={c.get("loop",0)}',f'YSYX_BRANCH_SPEC_HISTORY={c.get("spec",0)}']
suite.defines=v3_defines
names=sys.argv[1:] or list(configs)
sys.argv=['verify_direction_difftest','--root',str(root),'--configs',*names,'--resume']
suite.main()
