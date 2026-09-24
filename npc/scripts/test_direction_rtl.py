#!/usr/bin/env python3
"""Check delayed query identities and table updates against an independent RTL test model."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from explore_frontend import NPC
from followup_branch import defines


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    rtl=NPC/'vsrc/riscv32';top='riscv32_direction_contract_tb'
    files=[rtl/'common'/f for f in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_pkg.sv']]
    files += [rtl/'core/frontend/riscv32_tage.sv',rtl/'core/frontend/riscv32_bht.sv',NPC/'tests/rtl'/f'{top}.sv']
    cases=[(16,0,4),(64,0,4),(64,1,4),(128,1,4),(64,2,4),(128,2,4),(16,1,1),(16,2,2)]
    results=[]
    for entries,policy,history in cases:
        name=f'n{entries}-p{policy}-h{history}';folder=out/name;folder.mkdir()
        config={'bht':entries,'direction_policy':policy,'history_bits':history}
        macros=['+define+YSYX_RV32_BASELINE','+define+YSYX_DCACHE_ENABLE=1',
                '+define+YSYX_DCACHE_CAPACITY_BYTES=256','+define+YSYX_DCACHE_WAY_COUNT=2','+define+YSYX_DCACHE_LINE_BYTES=16']
        macros += ['+define+'+s for s in defines(config)]
        command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',*macros,'--top-module',top,'--Mdir',str(folder/'obj'),*map(str,files)]
        for cmd,log in [(command,'build.log'),([str(folder/'obj'/f'V{top}')],'run.log')]:
            with (folder/log).open('w') as f:
                subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,check=True)
        text=(folder/'run.log').read_text();assert 'PASS direction' in text
        results.append({'name':name,'config':config,'command':command,'result':text})
        print(text.strip(),flush=True)
        (out/'results.json').write_text(json.dumps({'results':results,'sources':{str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}},indent=2)+'\n')


if __name__=='__main__':main()
