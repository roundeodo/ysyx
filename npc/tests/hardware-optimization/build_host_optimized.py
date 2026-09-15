#!/usr/bin/env python3
"""Recompile an archived Verilator model, verify all test counters, then run fixed train."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('variant')
parser.add_argument('generated_directory', type=Path)
parser.add_argument('artifacts', type=Path)
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()
npc = Path(__file__).resolve().parents[2]
root = args.artifacts.resolve()
output = root / args.variant
source = args.generated_directory.resolve()
build = npc / 'build/hardware-optimization' / f'host-o3-{args.variant}'
binary = output / 'simulator-o3'
flags = ['OPT_FAST=-O3 -march=native', 'OPT_GLOBAL=-O3 -march=native', 'OPT_SLOW=-O1']
if not args.skip_build:
    build.mkdir(parents=True, exist_ok=True)
    for file in source.iterdir():
        if file.suffix in ['.cpp', '.h', '.mk']:
            shutil.copy2(file, build / file.name)
    makefile = build / 'VysyxSoCFull.mk'
    makefile.write_text(makefile.read_text().replace(str(source.parent / 'ysyxSoCFull_sim'), str(binary)))
    started = time.time()
    with (output / 'host-o3-build.log').open('w') as log:
        result = subprocess.run(['make', '-C', str(build), '-f', 'VysyxSoCFull.mk', '-j', '2', *flags],
                                stdout=log, stderr=subprocess.STDOUT)
    (output / 'host-o3-build.json').write_text(json.dumps({
        'exit_code': result.returncode, 'wall_seconds': time.time() - started,
        'source_generated_directory': str(source), 'flags': flags,
    }, indent=2) + '\n')
    if result.returncode:
        raise SystemExit(result.returncode)

images = [('test', npc / 'result/performance/rv32-microbench-test-20260906/microbench-riscv32-ysyxsoc-sdram.bin'),
          ('train', root / 'train.bin')]
for scale, image in images:
    started = time.time()
    log_path = output / f'{scale}-o3.log'
    with log_path.open('w') as log:
        result = subprocess.run([str(binary), '--batch', '--flash', str(image)],
                                stdout=log, stderr=subprocess.STDOUT)
    (output / f'{scale}-o3-run.json').write_text(json.dumps({
        'exit_code': result.returncode, 'wall_seconds': time.time() - started,
        'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
        'simulator_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    }, indent=2) + '\n')
    if result.returncode:
        raise SystemExit(result.returncode)
    result_path = output / f'{scale}-o3.json'
    subprocess.run(['python3', str(npc / 'scripts/analyze_issue_window.py'),
                    str(log_path), '--output', str(result_path)], check=True)
    if scale == 'test':
        if json.loads(result_path.read_text()) != json.loads((output / 'test.json').read_text()):
            raise SystemExit('Host compiler changed guest measurements; train not started')
        (output / 'host-o3-verified.json').write_text(json.dumps({
            'status': 'passed', 'all_test_measurements_identical': True,
            'simulator_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'flags': flags,
        }, indent=2) + '\n')
        print(f'{args.variant}: host compilation verified; starting train', flush=True)
    else:
        shutil.copy2(result_path, output / 'train.json')
