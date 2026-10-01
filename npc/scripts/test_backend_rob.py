#!/usr/bin/env python3
"""Randomized ROB reference queue: completion, backpressure, recovery and slot reuse."""
import argparse
import json
import subprocess
from pathlib import Path
from test_muldiv import NPC, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    rtl = NPC / 'vsrc/riscv32'
    sources = [rtl / p for p in ['common/riscv_config_pkg.sv', 'common/riscv32_addr_map_pkg.sv',
               'common/riscv32_pkg.sv', 'core/writeback/riscv32_rob.sv']]
    sources += [NPC / 'tests/backend/riscv32_rob_tb.sv']
    records = []
    for entries in [2, 4, 8]:
        flags = subprocess.check_output(['make', '-s', '-C', str(NPC),
            'NPC_CONFIG=rv32im-pipelined', f'NPC_BACKEND_ENTRIES={entries}',
            '--eval=backend-flags:;@echo $(NPC_CONFIG_DEFINE)', 'backend-flags'], text=True).split()
        obj = out / f'obj-{entries}'
        command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
                   *flags, '--top-module', 'riscv32_rob_tb', '--Mdir', str(obj), *map(str, sources)]
        run(command, out / f'build-{entries}.log')
        run([str(obj / 'Vriscv32_rob_tb')], out / f'run-{entries}.log')
        print((out / f'run-{entries}.log').read_text().strip(), flush=True)
        records.append({'entries': entries, 'cycles': 10000, 'passed': True, 'build': command})
    (out / 'report.json').write_text(json.dumps(records, indent=2)+'\n')


if __name__ == '__main__':
    main()
