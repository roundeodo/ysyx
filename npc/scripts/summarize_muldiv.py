#!/usr/bin/env python3
"""Collect compact, versioned RV32IM evidence; keep raw log paths and hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root, output = args.root.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    variants = {'i720': 'microbench-i', 'im720': 'microbench-im-resume',
                'i580': 'microbench-i-580-fixed', 'im580': 'microbench-im-580-fixed',
                'control': 'microbench-im-hardware-i-software'}
    performance, manifests = {}, {}
    for name, folder in variants.items():
        path = root / folder
        performance[name], manifests[name] = read(path / 'report.json'), read(path / 'manifest.json')
        assert performance[name]['status'] == 'passed'
        for file in ['report.json', 'manifest.json']:
            shutil.copy2(path / file, output / f'{name}-{file}')
    models = {k: v for k, v in manifests['i720']['sources'].items() if k.startswith('ysyxSoC/')}
    for manifest in manifests.values():
        assert {k: v for k, v in manifest['sources'].items() if k.startswith('ysyxSoC/')} == models
    for key in ['total', 'scored', 'whole_program']:
        assert performance['i720'][key] == performance['control'][key]
    for a, b in [('i720', 'i580'), ('im720', 'im580')]:
        assert manifests[a]['artifacts']['microbench.bin'] == manifests[b]['artifacts']['microbench.bin']
    ppa = {}
    for name in ['rv32i', 'rv32im', 'rv32i-current']:
        path = root / 'ppa' / name
        ppa[name] = read(path / 'qualified.json')
        assert ppa[name]['all_groups_passed']
        for file in ['qualified.json', 'timing.json', 'source-hashes.json', 'command.json']:
            shutil.copy2(path / file, output / f'{name}-{file}')
    for folder in ['unit-final', 'core-tests', 'quantized-dot']:
        shutil.copy2(root / folder / 'report.json', output / f'{folder}.json')
    shutil.copy2(root / 'baseline.json', output / 'baseline.json')
    # Raw logs include failed/interrupted attempts; successful runs are named explicitly.
    index = {str(p.relative_to(root)): {'bytes': p.stat().st_size, 'sha256': sha(p)}
             for p in sorted(root.rglob('*.log'))}
    (output / 'raw-log-index.json').write_text(json.dumps(index, indent=2)+'\n')
    names = ['qsort','queen','bf','fib','sieve','15pz','dinic','lzip','ssort','md5']
    for name in ['i580', 'im580']:
        assert len(performance[name]['subtests']) == len(names)
    summary = {'same_frequency_mhz': 580, 'same_soc_sources': models,
        'ppa': ppa, 'same_image_control_identical': True,
        'native_timer_hz': performance['i580']['timer_hz'], 'train_measured': False,
        'total_time_reduction': 1-performance['im580']['total']['timer_seconds']/performance['i580']['total']['timer_seconds'],
        'scored_time_reduction': 1-performance['im580']['scored']['timer_seconds']/performance['i580']['scored']['timer_seconds'],
        'area_increase_over_frozen_i': ppa['rv32im']['area_um2']/ppa['rv32i']['area_um2']-1,
        'area_time_ratio_same_frequency': ppa['rv32im']['area_um2']*performance['im580']['total']['cycle_seconds'] /
            (ppa['rv32i-current']['area_um2']*performance['i580']['total']['cycle_seconds']),
        'frequency_model_limit': 'Identical images are faster in timer seconds at 580 than 720 MHz; '
            'cross-frequency totals are model outputs, not reliable physical speedup claims. '
            'RV32I dirty miss: 488.508 cycles/720MHz versus 310.502 cycles/580MHz; clean misses scale approximately linearly.',
        'subtests': {name: {variant: performance[variant]['subtests'][i] for variant in ['i580','im580']}
                    for i, name in enumerate(names)},
        'validation_logs': ['unit-final-driver.log', 'core-tests-driver.log', 'regression-resume-driver.log',
                            'interrupt-580-driver.log', 'fence-muldiv-driver.log', 'rv64-regression.log'],
        'raw_root': str(root)}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps({k: v for k, v in summary.items() if isinstance(v, (float,int,bool))}, indent=2))


if __name__ == '__main__':
    main()
