#!/usr/bin/env python3
"""Build and measure the current RTL with one explicit CPU timing frequency."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('artifacts', type=Path)
parser.add_argument('--cpu-mhz', type=int, default=820)
args = parser.parse_args()
if not 100 <= args.cpu_mhz <= 4000:
    parser.error('CPU frequency must be an integer from 100 through 4000 MHz')
npc = Path(__file__).resolve().parents[2]
workspace = npc.parent
root = args.artifacts.resolve()
output = root / f'lsu-completion-issue-calibrated-{args.cpu_mhz}'
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, NPC_HOME=str(npc), AM_HOME=str(workspace / 'abstract-machine'))
command = ['make', '-C', str(npc), 'NPC_CONFIG=rv32-baseline', 'git_commit=',
           f'NPC_SIM_CPU_FREQ_MHZ={args.cpu_mhz}',
           'CAPSTONE_HOME=/home/yong/ysyx/ysyx-workbench/nemu/tools/capstone/repo',
           'VERILATOR_FLAGS=-MMD --build -cc -Wall -Wno-fatal -O3 --x-assign fast '
           '--x-initial fast --trace --autoflush --timescale 1ns/1ns --no-timing -j 2 '
           '-MAKEFLAGS "OPT_FAST=-O3 OPT_GLOBAL=-O3 OPT_SLOW=-O1"',
           'build-soc']
sources = list((npc / 'vsrc/riscv32').rglob('*.sv')) + [
    workspace / 'ysyxSoC/perip/amba/axi4_delayer.v',
    workspace / 'ysyxSoC/perip/amba/apb_delayer.v',
    workspace / 'ysyxSoC/build/ysyxSoCFull.v', npc / 'Makefile']
manifest = {'cpu_mhz': args.cpu_mhz, 'device_mhz': 100,
            'clint_cycles_per_us': args.cpu_mhz,
            'delay_ratio_scaled': args.cpu_mhz * 1024 // 100, 'delay_scale': 1024,
            'comparison_scope': 'new timing environment; do not attribute changes to RTL optimization',
            'build_command': command,
            'sources': {str(p.relative_to(workspace)): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in sources}}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

def run(command, name):
    started = time.monotonic()
    with (output / f'{name}.log').open('w') as log:
        result = subprocess.run(command, env=env, cwd=workspace, stdout=log, stderr=subprocess.STDOUT)
    (output / f'{name}-run.json').write_text(json.dumps({
        'exit_code': result.returncode, 'host_wall_seconds': time.monotonic() - started,
    }, indent=2) + '\n')
    if result.returncode:
        raise SystemExit(f'{name} failed: {output / (name + ".log")}')

run(command, 'build')
paths = list((npc / 'build/riscv32/rv32-baseline/icache-256b-way-1-line-16b/'
              'dcache-256b-way-2-line-16b/predictor-bht-16-btb-16x2-ras-4').glob(
                  f'sim-cpu-{args.cpu_mhz}mhz-device-100mhz/ysyxSoCFull_sim'))
if len(paths) != 1:
    raise SystemExit('Expected one explicitly calibrated simulator')
binary = paths[0]
manifest['simulator_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
for scale, image in [
    ('test', npc / 'result/performance/rv32-microbench-test-20260906/microbench-riscv32-ysyxsoc-sdram.bin'),
    ('train', root / 'train.bin'),
]:
    print(f'Running calibrated {args.cpu_mhz} MHz {scale}', flush=True)
    run([str(binary), '--batch', '--flash', str(image)], scale)
    subprocess.run(['python3', str(npc / 'scripts/analyze_issue_window.py'),
                    str(output / f'{scale}.log'), '--output', str(output / f'{scale}.json')],
                   check=True)
