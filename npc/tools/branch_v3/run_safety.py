#!/usr/bin/env python3
"""Keep the existing architecture/safety expectations; no skipped failure cases."""
import argparse,json,subprocess,sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];sys.path.insert(0,str(NPC/'scripts'))
from followup_branch import defines
configs={'NSL-victim':{'direction_policy':5,'sc':1,'loop':1},'B0-victim':{},'NSL-provider':{'direction_policy':5,'sc':1,'loop':1},'H2E-narrow':{'choice':2,'early':1},'R0-held':{'ras':1},'NSmallER-held':{'direction_policy':5,'ras':1,'early':1,'small':1},'N0-spec-final':{'direction_policy':5,'spec':1},'NSmallER':{'direction_policy':5,'ras':1,'early':1,'small':1},'R0':{'ras':1},'ER0':{'ras':1,'early':1},'NER0':{'direction_policy':5,'ras':1,'early':1},'B0-current':{},'E0':{'early':1},'NSL':{'direction_policy':5,'sc':1,'loop':1},'N0-spec':{'direction_policy':5,'spec':1}}
from run_btb_matrix import CONFIGS as BTB_CONFIGS
configs.update(BTB_CONFIGS)
from run_btb_extended import CONFIGS as JOINT_CONFIGS
configs.update(JOINT_CONFIGS)
configs['H2E-victim']={'choice':2,'early':1}
for matrix in ['btb-ablation-extension.json', 'btb-direction-extension.json',
               'btb-simple-direction-extension.json', 'btb-replacement-rtl-matrix.json']:
    configs.update(json.loads((NPC/'docs/research/branch-v3'/matrix).read_text()))
p=argparse.ArgumentParser();p.add_argument('names',nargs='+',choices=configs);a=p.parse_args()
for name in a.names:
    c=configs[name];out=NPC/'result/branch-v3/safety'/name;out.mkdir(parents=True,exist_ok=False)
    options=[d.replace('YSYX_','NPC_',1) for d in defines(c)]
    options += [f'NPC_BRANCH_STATIC_POLICY={c.get("choice",0)}',f'NPC_BRANCH_EARLY_RAS={c.get("ras",0)}',f'NPC_BRANCH_EARLY_TARGET={c.get("early",0)}',f'NPC_BRANCH_SC_ENABLE={c.get("sc",0)}',f'NPC_BRANCH_LOOP_ENABLE={c.get("loop",0)}',f'NPC_BRANCH_SPEC_HISTORY={c.get("spec",0)}']
    if c.get('small'):options += ['NPC_BRANCH_TAGE_BASE_ENTRIES=16','NPC_BRANCH_TAGE_TAGGED_ENTRIES=8','NPC_BRANCH_TAGE_TAG_BITS=6','NPC_BRANCH_TAGE_TABLE_COUNT=2']
    options += [f'FRONTEND_TEST_OUTPUT={out/"frontend"}',f'CACHE_RECOVERY_OUTPUT={out/"recovery"}',f'EXCEPTION_TEST_OUTPUT={out/"exception"}']
    records=[]
    for goal in ['test-fetch','test-fence-i','test-dcache-recovery','test-precise-exception']:
        command=['make','-C',str(NPC),'git_commit=','NPC_CONFIG=rv32-baseline',*options,goal]
        with (out/(goal+'.log')).open('x') as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
        records.append({'command':command,'returncode':result.returncode})
        (out/'results.json').write_text(json.dumps(records,indent=2)+'\n')
        if result.returncode:raise SystemExit(f'FAIL {name} {goal}; original log preserved')
        print('PASS',name,goal,flush=True)
