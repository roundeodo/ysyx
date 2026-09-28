#!/usr/bin/env python3
"""Run arithmetic, overlap and architectural recovery checks for the multiply pipeline."""

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

NPC = Path(__file__).resolve().parents[1]
ROOT = NPC.parent
TESTS = ('unit', 'core', 'arithmetic', 'exception', 'fence', 'interrupt', 'kernel')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--simulator', required=True, type=Path)
    parser.add_argument('--cpu-mhz', type=int, default=700)
    parser.add_argument('--tests', nargs='+', choices=TESTS, default=list(TESTS))
    args = parser.parse_args()
    output = args.output.resolve()
    simulator = args.simulator.resolve()
    if not simulator.is_file() or args.cpu_mhz <= 0:
        parser.error('Provide an existing pipelined simulator and a positive frequency')
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'regressions.json').exists():
        parser.error('Use a new output directory to preserve earlier results')

    env = dict(os.environ, NPC_HOME=str(NPC), AM_HOME=str(ROOT / 'abstract-machine'),
               NEMU_HOME=str(ROOT / 'nemu'),
               NPC_INTERRUPT_TEST_OUTPUT=str(output / 'interrupt'))
    flags = subprocess.check_output([
        'make', '-s', '-C', str(NPC), 'NPC_CONFIG=rv32im-pipelined',
        f'NPC_SIM_CPU_FREQ_MHZ={args.cpu_mhz}',
        '--eval=flags:;@echo $(NPC_CONFIG_DEFINE)', 'flags',
    ], env=env, text=True).split()
    tasks = {
        'unit': ['python3', str(NPC / 'scripts/test_mul_pipeline.py'),
                 '--output', str(output / 'unit')],
        'core': ['python3', str(NPC / 'scripts/test_mul_pipeline_core.py'),
                 '--simulator', str(simulator), '--output', str(output / 'core')],
        'arithmetic': ['python3', str(NPC / 'scripts/test_muldiv_core.py'),
                       '--simulator', str(simulator), '--output', str(output / 'arithmetic')],
        'exception': ['python3', str(NPC / 'tests/exception/run.py'),
                      '--output', str(output / 'exception'), *flags],
        'fence': ['python3', str(NPC / 'scripts/test_cache_recovery.py'), '--test', 'core',
                  '--output', str(output / 'fence'), *flags],
        'interrupt': ['python3', str(NPC / 'tests/interrupt/run.py'), *flags],
        'kernel': ['python3', str(NPC / 'scripts/measure_muldiv_kernel.py'),
                   '--simulator', str(simulator), '--output', str(output / 'kernel')],
    }
    report = {
        'simulator': str(simulator),
        'simulator_sha256': hashlib.sha256(simulator.read_bytes()).hexdigest(),
        'rtl_test_cpu_mhz': args.cpu_mhz,
        'note': 'The supplied standalone simulator retains its build frequency; '
                'core and kernel comparisons use cycles, not a native SoC timer.',
        'tests': [],
    }
    for name in args.tests:
        command = tasks[name]
        log_path = output / f'{name}-driver.log'
        print(f'START {name}', flush=True)
        with log_path.open('x') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                    stderr=subprocess.STDOUT)
        report['tests'].append({'name': name, 'command': command,
                                'exit_code': result.returncode, 'log': str(log_path)})
        (output / 'regressions.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'END {name}: {result.returncode}', flush=True)
        if result.returncode:
            print(log_path.read_text()[-4000:])
            raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
