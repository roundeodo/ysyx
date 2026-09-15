#!/usr/bin/env python3
"""Run reset and execution-result timing regression with the selected configuration."""
import os
from pathlib import Path
import subprocess
import sys

npc = Path(__file__).resolve().parents[2]
build = npc / 'build/tests/timing'
build.mkdir(parents=True, exist_ok=True)
if not sys.argv[1:]:
    raise SystemExit('Use make test-timing with an explicit NPC_CONFIG')
for top in ['riscv32_reset_controller_tb', 'riscv32_execute_result_timing_tb']:
    log = build / f'{top}.log'
    command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
               '--top-module', top, '--Mdir', str(build / top), *sys.argv[1:],
               '-f', str(npc / 'vsrc/riscv32/filelist/filelist.f'),
               str(Path(__file__).parent / f'{top}.sv')]
    with log.open('w') as output:
        result = subprocess.run(command, env=dict(os.environ, NPC_HOME=str(npc)),
                                stdout=output, stderr=subprocess.STDOUT, timeout=300)
    if result.returncode:
        print(log.read_text()[-6000:])
        raise SystemExit(result.returncode)
    subprocess.run([str(build / top / f'V{top}')], check=True, timeout=60)
