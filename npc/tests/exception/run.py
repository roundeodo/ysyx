#!/usr/bin/env python3
"""Check that an older trap prevents younger LSU, AXI and commit side effects."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess

NPC = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=NPC / 'build/tests/exception')
args, defines = parser.parse_known_args()
if not defines:
    parser.error('use make test-precise-exception with NPC_CONFIG=rv32-baseline')
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
top = 'riscv32_precise_exception_tb'
command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
           '--top-module', top, '--Mdir', str(out / 'obj'),
           f'-I{NPC / "vsrc/riscv32/sim"}', *defines,
           '-f', str(NPC / 'vsrc/riscv32/filelist/filelist_sta.f'),
           str(Path(__file__).with_name(top + '.sv'))]
with (out / 'build.log').open('w') as log:
    result = subprocess.run(command, env=dict(os.environ, NPC_HOME=str(NPC)),
                            stdout=log, stderr=subprocess.STDOUT, timeout=300)
if result.returncode:
    print((out / 'build.log').read_text()[-6000:])
    raise SystemExit(result.returncode)
results = []
for mode in range(4):
    for load in (0, 1):
        for mmio in (0, 1):
            for delay in (0, 80):
                name = f'mode{mode}-load{load}-mmio{mmio}-delay{delay}'
                run = [str(out / 'obj' / ('V' + top)), f'+mode={mode}', f'+load={load}',
                       f'+mmio={mmio}', f'+delay={delay}']
                with (out / f'{name}.log').open('w') as log:
                    result = subprocess.run(run, stdout=log, stderr=subprocess.STDOUT, timeout=60)
                text = (out / f'{name}.log').read_text()
                passed = result.returncode == 0 and 'PASS precise exception' in text
                results.append({'name': name, 'command': run, 'exit': result.returncode,
                                'passed': passed,
                                'result': [line for line in text.splitlines() if line.startswith('RESULT')]})
                if not passed:
                    print(text[-6000:])
manifest = {'build_command': command, 'cases': results,
            'source_sha256': {str(p.relative_to(NPC)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in [*sorted((NPC / 'vsrc/riscv32').rglob('*.sv')),
                                        Path(__file__), Path(__file__).with_name(top + '.sv')]}}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
passed_count = sum(case['passed'] for case in results)
print(f'Precise exception: {passed_count}/{len(results)} passed')
raise SystemExit(0 if passed_count == len(results) else 1)
