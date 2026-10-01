#!/usr/bin/env python3
"""Bounded invalidation priority plus combinational hybrid selection proof."""
import argparse,json,subprocess
from pathlib import Path
NPC=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--name',default='formal-current');a=p.parse_args()
r=NPC/'result/branch-v3'/a.name;r.mkdir(exist_ok=False)
source=NPC/'vsrc/riscv32/core/frontend'
manifest=json.loads((NPC/'result/branch-v3/builds/B0-final-off/manifest.json').read_text())
defines=' '.join(x.replace('+define+','-D',1) for x in manifest['command'] if x.startswith('+define+'))
commands={
 'choice':f'read_slang -DFORMAL {defines} --top choice_formal {NPC}/vsrc/riscv32/common/riscv_config_pkg.sv {source}/riscv32_branch_choice.sv {NPC}/tests/branch_v3/choice_formal.sv; prep -top choice_formal -flatten; chformal -lower; sat -set-assumes -verify -prove-asserts -show-inputs',
 'invalidate':f'read_slang -DFORMAL -DBRANCH_V3_VERIFY --top invalidate_formal {source}/riscv32_tage_scl.sv {NPC}/tests/branch_v3/invalidate_formal.sv; prep -top invalidate_formal -flatten; async2sync; chformal -lower; memory_map; opt_clean; sat -seq 4 -set-assumes -verify -prove-asserts -show-inputs'}
records=[]
for name,script in commands.items():
 path=r/(name+'.ys');path.write_text(script+'\n')
 command=['yosys','-m','slang','-s',str(path)]
 with (r/(name+'.log')).open('x') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
 records.append({'name':name,'command':command,'scope':'combinational proof' if name=='choice' else 'four-step bounded proof, small geometry, reset assumed initially','status':'passed'})
 (r/'results.json').write_text(json.dumps(records,indent=2)+'\n')
 print('PASS formal',name,flush=True)
