#!/usr/bin/env python3
"""Check cumulative physical timing, legacy timing, stalls and R payload holding."""
import argparse
from itertools import product
import json
from pathlib import Path

from explore_frontend import NPC, TEST, run, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sources = [NPC / 'vsrc/riscv32/common/riscv_config_pkg.sv',
               NPC / 'vsrc/riscv32/common/riscv32_axi4_pkg.sv',
               TEST / 'axi_memory.sv', TEST / 'memory_timing_tb.sv']
    settings = {'BRANCH_HISTORY_ENTRY_COUNT':16, 'BRANCH_TARGET_ENTRY_COUNT':16,
                'BRANCH_TARGET_WAY_COUNT':2, 'RETURN_STACK_ENTRY_COUNT':4,
                'ICACHE_CAPACITY_BYTES':256, 'ICACHE_WAY_COUNT':1, 'ICACHE_LINE_BYTES':16,
                'DCACHE_ENABLE':1, 'DCACHE_CAPACITY_BYTES':256, 'DCACHE_WAY_COUNT':2, 'DCACHE_LINE_BYTES':16}
    command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
               '+define+YSYX_RV32_BASELINE', '--top-module', 'exploration_memory_timing_tb', '--Mdir', out / 'obj',
               *[f'+define+YSYX_{k}={v}' for k, v in settings.items()], *sources]
    run(command, out / 'build.log')
    binary = out / 'obj/Vexploration_memory_timing_tb'
    records = []
    for mode, mhz, first, beat, count, stalls in product(
            ['cycle', 'physical'], [380, 580, 620, 720, 780, 800], [20, 100, 200],
            [10, 20], [1, 4, 8, 16], [0, 1, 2, 3]):
        label = f'{mode}-{mhz}-{first}-{beat}-{count}-{stalls}'
        command = [binary, f'+memory_mode={mode}', f'+cpu_mhz={mhz}', f'+latency_ns={first}',
                   f'+beat_ns={beat}', f'+burst_beats={count}', f'+probe_stalls={stalls}',
                   '+accept_after=10', '+present_at=1']
        run(command, out / (label + '.log'))
        records.append({'case': label, 'command': list(map(str, command)), 'status': 'passed'})
    # Presenting AR earlier must not start service before acceptance.
    for mode, present in product(['cycle', 'physical'], [1, 8, 15]):
        command = [binary, f'+memory_mode={mode}', f'+present_at={present}', '+accept_after=10']
        run(command, out / f'accept-{mode}-{present}.log')
        records.append({'case': f'accept-{mode}-{present}', 'command': list(map(str, command)), 'status': 'passed'})
    (out / 'manifest.json').write_text(json.dumps({'status': 'passed', 'cases': len(records),
        'sources': {str(p): sha(p) for p in sources}, 'binary_sha256': sha(binary),
        'records': records}, indent=2) + '\n')
    print('PASS', len(records), 'independent reference memory cases', flush=True)


if __name__ == '__main__':
    main()
