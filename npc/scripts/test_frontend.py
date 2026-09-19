#!/usr/bin/env python3
"""Build and run independent frontend contract tests with the selected NPC macros."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=NPC / 'build/tests/frontend')
    parser.add_argument('--test', choices=['predictor', 'icache', 'fetch'], default='predictor')
    parser.add_argument('defines', nargs='+')
    args = parser.parse_args()
    output = args.output.resolve() / args.test
    output.mkdir(parents=True, exist_ok=True)
    rtl = NPC / 'vsrc/riscv32'
    sources = [rtl / 'common' / name for name in
               ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_pkg.sv', 'riscv32_axi4_pkg.sv']]
    if args.test in ('predictor', 'fetch'):
        modules = ['bht', 'btb', 'ras', 'branch_predictor']
    else:
        modules = ['pma', 'icache_tag_array', 'icache_data_array', 'icache_miss_unit', 'icache', 'icache_axi']
    sources += [rtl / 'core/frontend' / f'riscv32_{name}.sv' for name in modules]
    if args.test == 'fetch':
        sources.append(rtl / 'core/frontend/riscv32_ifu.sv')
    top = f'riscv32_{args.test}_contract_tb'
    sources += [NPC / 'tests/rtl' / f'{top}.sv']
    command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
               *args.defines, '--top-module', top, '--Mdir', str(output / 'obj'), *map(str, sources)]
    for cmd, log in [(command, 'build.log'), ([str(output / 'obj' / f'V{top}')], 'run.log')]:
        with (output / log).open('w') as stream:
            result = subprocess.run(cmd, cwd=NPC, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            print((output / log).read_text()[-12000:])
            raise SystemExit(result.returncode)
    print((output / 'run.log').read_text())
    (output / 'manifest.json').write_text(json.dumps({
        'status': 'passed', 'command': command,
        'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
