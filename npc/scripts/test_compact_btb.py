#!/usr/bin/env python3
"""Exercise target width boundaries and migration with a full-address reference."""
import argparse
import json
from pathlib import Path
import subprocess
from compact_target_artifacts import prune_objects
from explore_frontend import NPC, sha
from explore_target_storage import defines


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--label', default='compact-btb')
    a = p.parse_args()
    root = a.root.resolve()
    out = root / 'verification' / a.label
    out.mkdir(parents=True, exist_ok=False)
    configs = json.loads((root / 'configurations.json').read_text())
    configs.pop('B0off')
    configs.update({name + '-taken': dict(configs[name], policy=1) for name in ['U16', 'H32']})
    configs['small-boundary'] = {'btb': 8, 'ways': 4, 'widths': [1, 2, 31, 32]}
    top = 'riscv32_compact_btb_tb'
    files = [NPC / 'vsrc/riscv32/common' / name for name in
             ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_pkg.sv']]
    files += [NPC / 'vsrc/riscv32/core/frontend' / name for name in
              ['riscv32_compact_btb.sv', 'riscv32_btb.sv']]
    files.append(NPC / 'tests/rtl' / (top + '.sv'))
    records = []
    for name, config in configs.items():
        folder = out / name
        folder.mkdir()
        macros = ['+define+YSYX_RV32_BASELINE', '+define+YSYX_DCACHE_ENABLE=1',
                  '+define+YSYX_DCACHE_CAPACITY_BYTES=256', '+define+YSYX_DCACHE_WAY_COUNT=2',
                  '+define+YSYX_DCACHE_LINE_BYTES=16']
        macros += ['+define+' + word for word in defines(config)]
        command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
                   *macros, '--top-module', top, '--Mdir', str(folder / 'obj'), *map(str, files)]
        for cmd, log in [(command, 'build.log'), ([str(folder / 'obj' / ('V' + top))], 'run.log')]:
            with (folder / log).open('w') as stream:
                subprocess.run(cmd, stdout=stream, stderr=subprocess.STDOUT, check=True)
        result = (folder / 'run.log').read_text()
        assert 'PASS compact BTB' in result
        records.append({'name': name, 'config': config, 'command': command, 'result': result,
                        'log_sha256': sha(folder / 'run.log')})
        (out / 'results.json').write_text(json.dumps({'sources': {str(path): sha(path) for path in files},
                                                    'results': records}, indent=2) + '\n')
        prune_objects(folder / 'obj')
        print(name, result.strip(), flush=True)


if __name__ == '__main__':
    main()
