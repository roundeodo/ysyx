#!/usr/bin/env python3
"""Check source-version selection, flow-through fetch FIFO, and explicit Issue register."""
import argparse
import json
import subprocess
from pathlib import Path
from test_muldiv import NPC, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    rtl = NPC / 'vsrc/riscv32'
    common = [rtl / 'common' / name for name in
              ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_pkg.sv']]
    cases = [('scoreboard', entries) for entries in [2, 4, 8]]
    cases += [('fetch_buffer', 4), ('issue_reg', 4)]
    records = []
    for module, entries in cases:
        label = f'{module}-{entries}'
        flags = subprocess.check_output(
            ['make', '-s', '-C', str(NPC), 'NPC_CONFIG=rv32im-pipelined',
             f'NPC_BACKEND_ENTRIES={entries}',
             '--eval=backend-flags:;@echo $(NPC_CONFIG_DEFINE)', 'backend-flags'],
            text=True).split()
        top = f'riscv32_{module}_tb'
        directory = 'frontend' if module == 'fetch_buffer' else 'decode'
        sources = [*common, rtl / 'core' / directory / f'riscv32_{module}.sv',
                   NPC / 'tests/backend' / f'{top}.sv']
        obj = output / f'obj-{label}'
        command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal',
                   '-j', '2', *flags, '--top-module', top, '--Mdir', str(obj)]
        command.extend(map(str, sources))
        run(command, output / f'build-{label}.log')
        run([str(obj / f'V{top}')], output / f'run-{label}.log')
        result = (output / f'run-{label}.log').read_text()
        assert 'PASS' in result
        print(result.splitlines()[0], flush=True)
        records.append({'name': label, 'passed': True, 'build': command,
                        'result': result.splitlines()[0]})
    (output / 'report.json').write_text(json.dumps(records, indent=2) + '\n')


if __name__ == '__main__':
    main()
