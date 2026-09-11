#!/usr/bin/env python3
"""Restore the pinned RV32 dependency patches without writing to upstream repos."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
bundle = root / 'npc/dependencies/rv32'
manifest = json.loads((bundle / 'manifest.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='Only verify the current dependency state')
args = parser.parse_args()

def run(*command, **options):
    return subprocess.run(command, cwd=root, check=True, **options)

if not args.check:
    run('git', 'submodule', 'update', '--init', 'am-kernels', 'ysyxSoC', 'nvboard', 'yosys-sta')
for name in ['am-kernels', 'ysyxSoC']:
    target = root / name
    patch = bundle / f'{name}.patch'
    if hashlib.sha256(patch.read_bytes()).hexdigest() != manifest[name]['patch_sha256']:
        raise SystemExit(f'{name}: patch hash mismatch')
    head = subprocess.check_output(['git', '-C', str(target), 'rev-parse', 'HEAD'], text=True).strip()
    if head != manifest[name]['base']:
        raise SystemExit(f'{name}: expected {manifest[name]["base"]}, found {head}')
    reverse = subprocess.run(['git', '-C', str(target), 'apply', '--reverse', '--check', str(patch)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if reverse.returncode == 0:
        print(f'{name}: patch already applied')
        continue
    if args.check:
        raise SystemExit(f'{name}: required patch is not applied')
    run('git', '-C', str(target), 'apply', '--check', str(patch))
    run('git', '-C', str(target), 'apply', str(patch))
    print(f'{name}: patch applied')
source = bundle / 'ysyxSoCFull.v'
target = root / 'ysyxSoC/build/ysyxSoCFull.v'
expected = manifest['generated_soc_sha256']
if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
    raise SystemExit('Archived generated SoC hash mismatch')
if target.exists():
    if hashlib.sha256(target.read_bytes()).hexdigest() != expected:
        raise SystemExit('Existing generated SoC differs; preserved it without overwriting')
elif args.check:
    raise SystemExit('Generated SoC is missing')
else:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
print('RV32 dependency patches and generated SoC verified')
