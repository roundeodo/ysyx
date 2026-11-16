#!/usr/bin/env python3
"""Check single-EX execution against NEMU using existing RV32I software images."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from result_workspace import ResultWorkspace

NPC = Path(__file__).resolve().parents[1]
WORKTREE = NPC.parent
TESTS = ['add', 'shift', 'load-store', 'if-else', 'recursion', 'quick-sort',
         'select-sort', 'bubble-sort', 'string', 'switch']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, env):
    with log.open('w') as stream:
        subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                       check=True, timeout=1200)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--registered', type=int, choices=[0, 1], default=0)
    parser.add_argument('--output', type=Path, default=NPC / 'result/ex-merge-difftest')
    args = parser.parse_args()
    reference = WORKTREE / 'nemu/build/riscv32-nemu-interpreter-so'
    images = WORKTREE / 'am-kernels/tests/cpu-tests/build'
    capstone = WORKTREE / 'nemu/tools/capstone/repo'
    if not (capstone / 'libcapstone.a').is_file():
        capstone = WORKTREE.parent / 'ysyx-workbench/nemu/tools/capstone/repo'
    assert reference.is_file() and (capstone / 'libcapstone.a').is_file()
    env = dict(os.environ, NPC_HOME=str(NPC))
    with ResultWorkspace(NPC, args.output, 'ex-merge-difftest') as work:
        command = ['make', '-C', str(NPC), 'build-npc', 'git_commit=',
                   'NPC_CONFIG=rv32-balanced', f'BUILD_DIR={work.root / "build"}',
                   f'NPC_EXECUTE_RESULT_REGISTERED={args.registered}',
                   f'CAPSTONE_HOME={capstone}']
        run(command, work.root / 'build.log', env)
        binaries = list((work.root / 'build').glob('*_sim'))
        assert len(binaries) == 1
        results = {'registered': args.registered, 'build_command': command,
                   'reference_sha256': sha(reference), 'binary_sha256': sha(binaries[0]),
                   'source_hashes': {str(p.relative_to(NPC)): sha(p)
                                     for p in (NPC / 'vsrc/riscv32').rglob('*.sv')},
                   'cases': []}
        for name in TESTS:
            image = images / f'{name}-riscv32-npc.bin'
            log = work.root / f'{name}.log'
            invocation = [str(binaries[0]), '--batch', '--diff', str(reference), str(image)]
            run(invocation, log, env)
            assert 'HIT GOOD TRAP' in log.read_text(), log
            results['cases'].append({'name': name, 'image_sha256': sha(image),
                                     'command': invocation, 'passed': True})
            (work.root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print('PASS NEMU', name, flush=True)


if __name__ == '__main__':
    main()
