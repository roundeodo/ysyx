#!/usr/bin/env python3
"""Compare real EXU address/branch outputs with independent arithmetic references."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from result_workspace import ResultWorkspace

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=NPC / 'result/ex-merge-arithmetic')
    parser.add_argument('defines', nargs='+')
    args = parser.parse_args()
    rtl = NPC / 'vsrc/riscv32'
    packages = [rtl / 'common' / name for name in
                ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv',
                 'riscv32_axi4_pkg.sv', 'riscv32_pkg.sv']]
    with ResultWorkspace(NPC, args.output, 'ex-merge-arithmetic') as work:
        results = []
        for name in ['address_add', 'branch_compare']:
            top = f'riscv32_{name}_tb'
            sources = packages + [rtl / 'core/execute/riscv32_exu.sv',
                                  NPC / 'tests/rtl' / f'{top}.sv']
            folder = work.root / name
            folder.mkdir()
            objects = work.root / 'build' / name
            objects.mkdir(parents=True)
            command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal',
                       '-j', '2', *args.defines, '--top-module', top,
                       '--Mdir', str(objects), *map(str, sources)]
            execute = [str(objects / f'V{top}')]
            record = {'build': command, 'run': execute,
                      'sources': {str(p.relative_to(NPC)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sources}}
            (folder / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
            for invocation, label in [(command, 'build'), (execute, 'run')]:
                with (folder / f'{label}.log').open('w') as log:
                    subprocess.run(invocation, stdout=log, stderr=subprocess.STDOUT,
                                   check=True, timeout=300)
            record['passed'] = True
            results.append(record)
            (work.root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print((folder / 'run.log').read_text().splitlines()[0], flush=True)


if __name__ == '__main__':
    main()
