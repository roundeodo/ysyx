#!/usr/bin/env python3
"""Run final integration checks and retain commands, logs and exit status."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

out = Path(__file__).resolve().parent
root = out.parents[3]
npc = root / 'npc'
env = dict(os.environ, NPC_HOME=str(npc), AM_HOME=str(root / 'abstract-machine'),
           NEMU_HOME=str(root / 'nemu'))
make = ['make', '-C', str(npc), 'git_commit=']
checks = {
    'difftest': ['make', '-C', str(root / 'am-kernels/tests/cpu-tests'), 'git_commit=',
        'ARCH=riscv32-npc', 'NPC_CONFIG=rv32-baseline', 'NPC_RUN_TARGET=sim-difftest',
        f'REF={root}/nemu/build/riscv32-nemu-interpreter-so',
        f'CAPSTONE_LIB={root.parent}/ysyx-workbench/nemu/tools/capstone/repo', 'run'],
    'interrupt': make + ['NPC_CONFIG=rv32-baseline', 'test-timer-interrupt'],
    'pipeline-lint': make + ['NPC_CONFIG=rv32-baseline', 'test-pipeline', 'lint-npc', 'lint-soc'],
    'rv64-memory': make + ['NPC_CONFIG=rv64-sequential', 'test-lsu', 'test-uncached'],
    'scc-system-bit': json.loads((out.parent / 'rv32-cycle-opt-20260919/scc-system-bit-command.json').read_text()),
}
sources = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in sorted((npc / 'vsrc/riscv32').rglob('*.sv'))}
(out / 'check-source-hashes.json').write_text(json.dumps(sources, indent=2) + '\n')
results = {}
for name, command in checks.items():
    (out / f'{name}-command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (out / f'{name}.log').open('w') as log:
        run = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
    (out / f'{name}.exit').write_text(str(run.returncode) + '\n')
    assert run.returncode == 0, f'{name}: see log'
    text = (out / f'{name}.log').read_text()
    if name == 'difftest':
        text = re.sub(r'\x1b\[[0-9;]*m', '', text)
        passed = len(re.findall(r'\[.*?\]\s+PASS', text))
        assert passed == 35 and not re.search(r'\[.*?\]\s+FAIL', text), text[-4000:]
        results[name] = {'passed': passed}
    else:
        results[name] = {'exit': run.returncode,
            'messages': [line for line in text.splitlines() if 'PASS' in line or 'Found 0 SCCs' in line]}
    (out / 'checks.json').write_text(json.dumps(results, indent=2) + '\n')
    print(name, 'passed', flush=True)
for name, digest in sources.items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name
