#!/usr/bin/env python3
"""Run an archived MicroBench image on another compatible archived simulator."""
import argparse
import copy
import json
from pathlib import Path
import shutil
import subprocess
from run_microbench_perf import NPC, sha256, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hardware-run', required=True, type=Path)
    parser.add_argument('--software-run', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    hw, sw, output = [p.resolve() for p in [args.hardware_run, args.software_run, args.output]]
    hardware = json.loads((hw / 'manifest.json').read_text())
    software = json.loads((sw / 'manifest.json').read_text())
    for key in ['cpu_mhz', 'device_mhz', 'icache', 'predictor', 'delay_ratio_scaled', 'delay_scale']:
        require(hardware[key] == software[key], f'Cannot compare different {key}')
    for path, digest in hardware['sources'].items():
        if path.startswith('ysyxSoC/'):
            require(software['sources'].get(path) == digest, f'SoC model changed: {path}')
    hardware_isa = hardware.get('hardware_isa', hardware.get('isa', 'rv32i'))
    require(hardware_isa == 'rv32im' or software.get('isa', 'rv32i') == 'rv32i',
            'RV32IM software needs M hardware')
    for folder, manifest in [(hw, hardware), (sw, software)]:
        for name, digest in manifest['artifacts'].items():
            require(sha256(folder / name) == digest, f'Changed input artifact: {folder / name}')
    output.mkdir(parents=True, exist_ok=False)
    for name in ['simulator', 'source-snapshot.tar.gz']:
        shutil.copy2(hw / name, output / name)
    for name in ['microbench.bin', 'microbench.elf', 'microbench.txt']:
        shutil.copy2(sw / name, output / name)
    shutil.copy2(sw / 'source-snapshot.tar.gz', output / 'software-snapshot.tar.gz')
    manifest = copy.deepcopy(hardware)
    manifest['hardware_isa'] = hardware_isa
    for key in ['isa', 'am_arch', 'scale', 'layout', 'image_build_command']:
        if key in software:
            manifest[key] = software[key]
    manifest['cross_run'] = {'hardware_manifest': str(hw / 'manifest.json'),
        'hardware_manifest_sha256': sha256(hw / 'manifest.json'),
        'software_manifest': str(sw / 'manifest.json'),
        'software_manifest_sha256': sha256(sw / 'manifest.json'),
        'sources_note': 'sources/source-snapshot describe hardware run; software snapshot retained separately'}
    manifest['artifacts'] = {name: sha256(output / name) for name in
                            [*hardware['artifacts'], 'software-snapshot.tar.gz']}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    subprocess.run(['python3', str(NPC / 'scripts/run_microbench_perf.py'), '--resume', str(output)], check=True)


if __name__ == '__main__':
    main()
