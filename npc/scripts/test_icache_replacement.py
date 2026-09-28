#!/usr/bin/env python3
"""Exercise replacement hint identity and independently probe the memory clock model."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess

NPC = Path(__file__).resolve().parents[1]


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('defines',nargs='+')
    args=parser.parse_args()
    out=args.output.resolve()
    out.mkdir(parents=True,exist_ok=False)
    rtl=NPC/'vsrc/riscv32';test=NPC/'tests/frontend_exploration'
    packages=[rtl/'common'/n for n in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_axi4_pkg.sv','riscv32_pkg.sv']]
    base=[x for x in args.defines if not any(k in x for k in ['ICACHE_CAPACITY_BYTES','ICACHE_WAY_COUNT','ICACHE_REPLACEMENT_POLICY'])]
    results=[]
    for policy,capacity in [(1,256),(2,256),(3,256),(3,32),(0,256)]:
        name=f'p{policy}-c{capacity}'
        folder=out/name;folder.mkdir()
        top='exploration_replacement_tb' if policy else 'exploration_memory_probe_tb'
        sources=packages+([rtl/'core/frontend/riscv32_icache_tag_array.sv',test/'replacement_tb.sv'] if policy else [test/'axi_memory.sv',test/'memory_probe_tb.sv'])
        command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',
                 '-MAKEFLAGS','OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0',*base,
                 f'+define+YSYX_ICACHE_CAPACITY_BYTES={capacity}','+define+YSYX_ICACHE_WAY_COUNT=2',
                 f'+define+YSYX_ICACHE_REPLACEMENT_POLICY={policy}','--top-module',top,'--Mdir',str(folder/'obj'),*map(str,sources)]
        record={'build':command,'sources':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},'runs':[]}
        with (folder/'build.log').open('w') as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
        if result.returncode:raise RuntimeError(str(folder/'build.log'))
        options=[[]] if policy else [[f'+present_at={start}','+accept_after=10',f'+cpu_mhz={mhz}'] for mhz in [100,500,580] for start in [1,8]]
        for index,option in enumerate(options):
            run=[str(folder/'obj'/('V'+top)),*option]
            with (folder/f'run-{index}.log').open('w') as log:
                result=subprocess.run(run,stdout=log,stderr=subprocess.STDOUT)
            if result.returncode:raise RuntimeError(str(folder/f'run-{index}.log'))
            record['runs'].append({'command':run,'passed':True})
        results.append(record)
        (out/'manifest.json').write_text(json.dumps(results,indent=2)+'\n')
    print('PASS replacement policies and service timing probes')


if __name__=='__main__':main()
