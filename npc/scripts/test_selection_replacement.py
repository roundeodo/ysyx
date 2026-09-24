#!/usr/bin/env python3
"""Cross-check policy RTL with C++ victim streams, including same-cycle bypass."""
import argparse
import json
from pathlib import Path
import random
import resource

from explore_frontend import NPC, run, sha

POLICIES = {4: 'lru', 5: 'plru', 6: 'random', 7: 'brrip', 8: 'drrip',
            9: 'burst_rrip', 10: 'burst_pc', 11: 'burst_history', 12: 'srrip',
            13: 'burst_rrip', 14: 'srrip', 15: 'burst_history', 16: 'burst_pc'}


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--policies', type=int, nargs='+', choices=POLICIES, default=list(POLICIES))
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    model_source = NPC / 'tools/icache_explore/model.cpp'
    run(['g++', '-std=c++17', '-O2', model_source, '-o', out / 'model'], out / 'model-build.log')
    rtl = NPC / 'vsrc/riscv32'
    sources = [rtl / 'common' / n for n in ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv',
                                           'riscv32_axi4_pkg.sv', 'riscv32_pkg.sv']]
    sources += [rtl / 'core/frontend/riscv32_icache_replacement.sv',
                NPC / 'tests/frontend_selection/replacement_tb.sv']
    manifest = {'sources': {str(p): sha(p) for p in [model_source, *sources]}, 'tests': []}
    for ways, sets, line in [(2, 8, 16), (4, 8, 32), (8, 1, 64)]:
        rng = random.Random(813)
        addresses = []
        # Hot returns interspersed with scans, aliasing, and repeated line hits.
        for index in range(5000):
            block = (rng.randrange(ways + 2) * sets + index % sets
                     if index % 97 < 60 else rng.randrange(ways * sets * 4))
            addresses += [0x80000000 + block * line] * rng.randrange(1, 5)
        trace = out / f'trace-{ways}-{sets}.csv'
        trace.write_text(''.join(f'{addr:x}\n' for addr in addresses))
        for policy, name in POLICIES.items():
            if policy not in args.policies:
                continue
            folder = out / f'w{ways}-s{sets}-p{policy}'
            folder.mkdir()
            config = folder / 'config.csv'
            config.write_text(f'{ways * sets * line},{ways},{line},{name}\n')
            run([out / 'model', trace, config, folder / 'model.csv', folder / 'events'], folder / 'model.log')
            command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
                       '-MAKEFLAGS', 'OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0',
                       '+define+YSYX_RV32_BASELINE', '+define+YSYX_DCACHE_ENABLE=1',
                       '+define+YSYX_DCACHE_CAPACITY_BYTES=256', '+define+YSYX_DCACHE_WAY_COUNT=2',
                       '+define+YSYX_DCACHE_LINE_BYTES=16', '+define+YSYX_BRANCH_HISTORY_ENTRY_COUNT=16',
                       '+define+YSYX_BRANCH_TARGET_ENTRY_COUNT=16', '+define+YSYX_BRANCH_TARGET_WAY_COUNT=2',
                       '+define+YSYX_RETURN_STACK_ENTRY_COUNT=4', f'+define+YSYX_ICACHE_CAPACITY_BYTES={ways * sets * line}',
                       f'+define+YSYX_ICACHE_WAY_COUNT={ways}', f'+define+YSYX_ICACHE_LINE_BYTES={line}',
                       f'+define+YSYX_ICACHE_REPLACEMENT_POLICY={policy}', '--top-module',
                       'selection_replacement_tb', '--Mdir', folder / 'obj', *sources]
            run(command, folder / 'build.log')
            execute = [folder / 'obj/Vselection_replacement_tb', f'+events={folder / "events"}']
            run(execute, folder / 'run.log')
            manifest['tests'].append({'build': list(map(str, command)), 'run': list(map(str, execute)),
                                      'trace_sha256': sha(trace), 'passed': True})
            (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
            print(folder.name, 'PASS', flush=True)


if __name__ == '__main__':
    main()
