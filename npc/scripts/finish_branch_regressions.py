#!/usr/bin/env python3
"""Run native-timer and safety regressions; never launch the long train run."""
import argparse
import json
from pathlib import Path
import subprocess
import time

from explore_frontend import NPC
from qualify_branch_runs import read


def wait_for(path, deadline):
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError(f'Required result is incomplete: {path}')
        time.sleep(10)


def microbench(root, name):
    cfg = read(root / 'configurations.json')[name]
    mhz = read(root / 'ppa' / name / 'qualified.json')['mhz']
    folder = root / 'microbench' / name
    path = folder / 'report.json'
    if not path.exists():
        if folder.exists():
            raise RuntimeError(f'Inspect preserved partial MicroBench run: {folder}')
        command = ['python3', str(NPC / 'scripts/run_microbench_perf.py'), '--scale', 'test',
                   '--cpu-mhz', str(mhz), '--icache-bytes', '1024', '--icache-ways', '4',
                   '--icache-line', '32', '--icache-policy', '13', '--bht-entries', str(cfg['bht']),
                   '--btb-entries', str(cfg['btb']), '--btb-ways', str(cfg['ways']),
                   '--btb-policy', str(cfg['policy']), '--ras-entries', str(cfg['ras']),
                   '--verify-observer', '--output', str(folder)]
        print('MICROBENCH TEST', name, mhz, flush=True)
        log = root / 'microbench' / (name + '-driver.log')
        log.parent.mkdir(exist_ok=True)
        with log.open('x') as stream:
            subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT)
    measured = read(path)
    assert measured['status'] == 'passed' and measured['observer_on_off_verified']
    assert measured['scale'] == 'test' and measured['cpu_mhz'] == mhz
    manifest = read(folder / 'manifest.json')
    assert manifest['predictor'] == {'bht_entries': cfg['bht'], 'btb_entries': cfg['btb'],
                                     'btb_ways': cfg['ways'], 'btb_policy': cfg['policy'],
                                     'ras_entries': cfg['ras']}
    assert manifest['icache'] == {'bytes': 1024, 'ways': 4, 'line_bytes': 32, 'policy': 13}
    baseline = read(root / 'microbench/B0/manifest.json')
    assert manifest['artifacts']['microbench.bin'] == baseline['artifacts']['microbench.bin']
    print('PASS native timer', name, measured['total']['timer_seconds'], flush=True)
    return {'name': name, 'report': str(path.relative_to(root)), 'mhz': mhz,
            'total': measured['total'], 'scored': measured['scored']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--wait-hours', type=float, default=12)
    args = parser.parse_args()
    root = args.root.resolve()
    deadline = time.monotonic() + args.wait_hours * 3600
    wait_for(root / 'ppa/B0/qualified.json', deadline)
    reports = [microbench(root, 'B0')]
    wait_for(root / 'validation-complete.json', deadline)
    frozen = read(root / 'selection-freeze.json')
    decision = read(root / 'decision.json')
    names = list(dict.fromkeys([decision['adopted_for_evaluation'], frozen['best_simple'], frozen['best_rrip']]))
    subprocess.run(['python3', str(NPC / 'scripts/verify_branch.py'), '--root', str(root),
                    '--configs', *names], check=True)
    for name in names:
        if name != 'B0':
            reports.append(microbench(root, name))
    (root / 'final-validation.json').write_text(json.dumps({
        'status': 'passed', 'safety_names': names, 'microbench_test': reports,
        'identical_microbench_image': True, 'observer_on_off_verified': True,
        'microbench_train_rerun': False,
    }, indent=2) + '\n')
    print('PASS all branch regressions', flush=True)


if __name__ == '__main__':
    main()
