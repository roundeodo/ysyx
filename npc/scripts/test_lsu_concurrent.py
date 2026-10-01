#!/usr/bin/env python3
"""Check two-slot LSU/cache identity, overlap, replay and stalled responses."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
from test_cache_recovery import NPC, run


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    out = a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    rtl = NPC / 'vsrc/riscv32'
    command = ['make', '-s', '-C', str(NPC), 'NPC_CONFIG=rv32im-pipelined',
               'NPC_BACKEND_ROB_ENABLE=1', 'NPC_BACKEND_LOAD_OVERLAP=1',
               'NPC_LSU_ENTRIES=2', 'NPC_DCACHE_HIT_UNDER_MISS=1',
               '--eval=f:;@echo $(NPC_CONFIG_DEFINE)', 'f']
    defines = subprocess.check_output(command, env=dict(os.environ, NPC_HOME=str(NPC)), text=True).split()
    sources = [rtl/'common'/n for n in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv',
                                       'riscv32_axi4_pkg.sv','riscv32_pkg.sv']]
    sources += [rtl/'core/frontend/riscv32_pma.sv']
    sources += [rtl/'core/memory'/f'riscv32_{n}.sv' for n in ['lsu','data_mem',
        'dcache','dcache_tag_array','dcache_data_array','dcache_miss_unit','dcache_axi','uncached_axi']]
    sources += [NPC/'tests/rtl/riscv32_lsu_concurrent_tb.sv']
    build = ['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',*defines,
             '--top-module','riscv32_lsu_concurrent_tb','--Mdir',str(out/'obj'),*map(str,sources)]
    report = {'build': build, 'sources': {str(s): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}, 'cases': []}
    (out/'manifest.json').write_text(json.dumps(report, indent=2)+'\n')
    run(build, out/'build.log')
    for seed in [1,2,3,5,7,11,31,73,123,557,1009,65535]:
        cmd = [str(out/'obj/Vriscv32_lsu_concurrent_tb'), f'+seed={seed}']
        log = out/f'seed{seed}.log'; run(cmd, log)
        assert 'PASS concurrent LSU' in log.read_text()
        report['cases'].append({'seed': seed, 'command':cmd,'result':log.read_text().splitlines()[0]})
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS concurrent LSU:',len(report['cases']),'seeds')

if __name__ == '__main__': main()
