#!/usr/bin/env python3
"""Check the reset controller and the actual system reset/AXI boundary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    npc = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('defines', nargs='+')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for top in ['riscv_reset_controller_tb', 'riscv_system_reset_tb']:
        obj = out / top
        command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal',
                   '-j', '2', '--top-module', top, '--Mdir', str(obj), *args.defines,
                   f'-I{npc / "vsrc/riscv/sim"}',
                   '-f', str(npc / 'vsrc/riscv/filelist/filelist_sta.f'),
                   str(Path(__file__).parent / (top + '.sv'))]
        with (out / (top + '-build.log')).open('w') as log:
            result = subprocess.run(command, env=dict(os.environ, NPC_HOME=str(npc)),
                                    stdout=log, stderr=subprocess.STDOUT, timeout=900)
        record = {'top': top, 'build_command': command, 'build_exit': result.returncode}
        if not result.returncode:
            with (out / (top + '-run.log')).open('w') as log:
                result = subprocess.run([str(obj / ('V' + top))], stdout=log,
                                        stderr=subprocess.STDOUT, timeout=60)
            record['run_exit'] = result.returncode
        results.append(record)
        (out / 'manifest.json').write_text(json.dumps(results, indent=2) + '\n')
        if result.returncode:
            raise SystemExit(result.returncode)
        print('PASS', top, flush=True)
    sources = [*npc.joinpath('vsrc/riscv').rglob('*.sv'), *Path(__file__).parent.glob('*.sv')]
    (out / 'source-hashes.json').write_text(json.dumps(
        {str(f.relative_to(npc)): hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},
        indent=2) + '\n')


if __name__ == '__main__':
    main()
