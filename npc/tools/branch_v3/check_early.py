#!/usr/bin/env python3
import argparse,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--returns',action='store_true');p.add_argument('--prove-hold-required',action='store_true');a=p.parse_args()
NPC=Path(__file__).resolve().parents[2];root=NPC/'result/branch-v3'/('early-return-without-hold' if a.prove_hold_required else ('early-return-contract' if a.returns else 'early-contract'));
if root.exists():
 import time
 root.rename(root.with_name('early-contract-attempt-'+time.strftime('%H%M%S')))
root.mkdir(exist_ok=False)
m=json.loads((NPC/'result/branch-v3/builds/N0/manifest.json').read_text())
defines=[x for x in m['command'] if x.startswith('+define+') and not x.startswith(('+define+YSYX_BRANCH_STATIC_POLICY=','+define+YSYX_BRANCH_EARLY_TARGET=','+define+YSYX_BRANCH_DIRECTION_POLICY=','+define+YSYX_BRANCH_EARLY_RAS='))]
sources=[Path(x) for x in m['sources'] if '/common/' in x or '/frontend/' in x]
if a.prove_hold_required:
 assert a.returns
 original=NPC/'vsrc/riscv32/core/frontend/riscv32_ifu.sv';mutated=root/'riscv32_ifu.sv'
 source=original.read_text().replace('return_hold_present_q ?\n        return_hold_usable_q : early_return_present_i','early_return_present_i').replace('return_hold_present_q ? return_hold_pc_q : early_return_pc_i','early_return_pc_i')
 assert source!=original.read_text();mutated.write_text(source)
 sources=[mutated if path.name==original.name else path for path in sources]
command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',*defines,'+define+YSYX_BRANCH_STATIC_POLICY=1','+define+YSYX_BRANCH_EARLY_TARGET=1','+define+YSYX_BRANCH_DIRECTION_POLICY=0',f'+define+YSYX_BRANCH_EARLY_RAS={int(a.returns)}',f'-GRETURN_TEST={int(a.returns)}','--top-module','early_target_tb','--Mdir',str(root/'obj'),*map(str,sources),str(NPC/'tests/branch_v3/early_target_tb.sv')]
with (root/'build.log').open('x') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
for seed in ([11] if a.prove_hold_required else [11,29,97,101,12347,90121]):
 with (root/f'{seed}.log').open('x') as f:result=subprocess.run([str(root/'obj/Vearly_target_tb'),f'+seed={seed}'],stdout=f,stderr=subprocess.STDOUT)
 if a.prove_hold_required:
  assert result.returncode and 'IFU changed a presented fetch entry while stalled' in (root/f'{seed}.log').read_text()
  print('DETECTED missing return hold',seed,flush=True)
 else:
  assert result.returncode==0
  print('PASS early',seed,flush=True)
(root/'command.json').write_text(json.dumps(command,indent=2)+'\n')
