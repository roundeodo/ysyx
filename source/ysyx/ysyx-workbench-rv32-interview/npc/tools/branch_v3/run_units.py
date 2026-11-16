#!/usr/bin/env python3
import json,subprocess
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];root=NPC/'result/branch-v3'
m=json.loads((root/'builds/H2/manifest.json').read_text());defs=['+define+'+k+(('='+str(v)) if v is not None else '') for k,v in m['settings'].items()]
for target,files in [('taken_tb',['common/riscv_config_pkg.sv','common/riscv32_addr_map_pkg.sv','common/riscv32_pkg.sv','core/execute/riscv32_exu.sv'])]:
 obj=root/(target+'-obj');command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2','--top-module',target,'--Mdir',str(obj),*defs,*[str(NPC/'vsrc/riscv32'/f) for f in files],str(NPC/'tests/branch_v3'/(target+'.sv'))]
 with (root/(target+'-build.log')).open('w') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
 with (root/(target+'-run.log')).open('w') as f:subprocess.run([str(obj/('V'+target))],stdout=f,stderr=subprocess.STDOUT,check=True)
 print('PASS',target)
