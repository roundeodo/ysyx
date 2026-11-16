#!/usr/bin/env python3
"""Validate the MicroBench window observer without running a processor workload."""
import os
from pathlib import Path
import subprocess
import sys

npc = Path(__file__).resolve().parents[2]
build = npc / 'build/tests/hardware-optimization/monitor'
build.mkdir(parents=True, exist_ok=True)
if not sys.argv[1:]:
    raise SystemExit('Use make test-issue-window with an explicit NPC_CONFIG')
command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
           '--top-module', 'riscv32_issue_window_tb', '--Mdir', str(build), *sys.argv[1:],
           '-f', str(npc / 'vsrc/riscv32/filelist/filelist.f'),
           str(Path(__file__).parent / 'riscv32_issue_window_tb.sv')]
with (build / 'build.log').open('w') as output:
    result = subprocess.run(command, env=dict(os.environ, NPC_HOME=str(npc)),
                            stdout=output, stderr=subprocess.STDOUT, timeout=300)
if result.returncode:
    print((build / 'build.log').read_text()[-6000:])
    raise SystemExit(result.returncode)
subprocess.run([str(build / 'Vriscv32_issue_window_tb')], check=True, timeout=60)
