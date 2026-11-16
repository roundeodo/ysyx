#!/usr/bin/env python3
"""Finish safety and native-timer regressions after the frozen held evaluation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from explore_frontend import NPC


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--wait-hours', type=float, default=8)
    args = parser.parse_args()
    root = args.root.resolve()
    deadline = time.monotonic() + args.wait_hours * 3600
    while not (root / 'validation-complete.json').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Held validation remains incomplete; resume this command later')
        time.sleep(10)
    subprocess.run(['python3', str(NPC / 'scripts/report_icache_selection.py'),
                    '--root', str(root)], check=True)
    decision = read(root / 'decision.json')
    freeze = read(root / 'selection-freeze.json')
    configs = {row['name']: row for row in freeze['rows']}
    names = list(dict.fromkeys([decision['adopted'], freeze['best_simple']]))
    safety = []
    for name in names:
        verified = None
        for folder in ['safety', 'query-safety-resume', 'learned-query-safety', 'final-safety-' + name]:
            manifest = root / folder / 'manifest.json'
            if manifest.exists():
                records = [record for record in read(manifest) if record['config'] == name]
                if len(records) == 4 and all(record['passed'] for record in records):
                    verified = manifest
                    break
        if verified is None:
            destination = root / ('final-safety-' + name)
            if destination.exists():
                raise RuntimeError(f'Preserve and inspect partial safety run before retry: {destination}')
            print('FINAL SAFETY', name, flush=True)
            subprocess.run(['python3', str(NPC / 'scripts/verify_icache_selection.py'),
                            '--output', str(destination), '--configs', name, '--full'], check=True)
            verified = destination / 'manifest.json'
        safety.append({'name': name, 'manifest': str(verified)})
    micro = []
    for name in list(dict.fromkeys(['B0', *names])):
        row = configs[name]
        capacity, ways, policy, line = row['config']
        destination = root / 'microbench' / f'{name}-{row["mhz"]}'
        if not (destination / 'report.json').exists():
            if destination.exists():
                raise RuntimeError(f'Preserve and inspect partial MicroBench run before retry: {destination}')
            print('NATIVE TIMER REGRESSION', name, flush=True)
            subprocess.run(['python3', str(NPC / 'scripts/run_microbench_perf.py'),
                            '--scale', 'test', '--cpu-mhz', str(row['mhz']),
                            '--icache-bytes', str(capacity), '--icache-ways', str(ways),
                            '--icache-policy', str(policy), '--icache-line', str(line),
                            '--verify-observer', '--output', str(destination)], check=True)
        measured = read(destination / 'report.json')
        assert measured['status'] == 'passed' and measured['observer_on_off_verified']
        assert measured['scale'] == 'test' and measured['cpu_mhz'] == row['mhz']
        manifest = read(destination / 'manifest.json')
        base_manifest = read(root / 'microbench' / f'B0-{configs["B0"]["mhz"]}' / 'manifest.json')
        assert manifest['artifacts']['microbench.bin'] == base_manifest['artifacts']['microbench.bin']
        micro.append({'name': name, 'report': str(destination / 'report.json'),
                      'total': measured['total'], 'scored': measured['scored']})
    interrupts = []
    for name in list(dict.fromkeys(['B0', *names])):
        row = configs[name]
        capacity, ways, policy, line = row['config']
        destination = root / 'interrupts' / name
        record = destination / 'validation.json'
        command = ['make', '-C', str(NPC), 'git_commit=', 'NPC_CONFIG=rv32-baseline',
                   f'NPC_SIM_CPU_FREQ_MHZ={row["mhz"]}',
                   f'NPC_ICACHE_CAPACITY_BYTES={capacity}', f'NPC_ICACHE_WAY_COUNT={ways}',
                   f'NPC_ICACHE_REPLACEMENT_POLICY={policy}', f'NPC_ICACHE_LINE_BYTES={line}',
                   'test-timer-interrupt']
        if not record.exists():
            destination.mkdir(parents=True, exist_ok=False)
            env = dict(os.environ, NPC_HOME=str(NPC),
                       NPC_INTERRUPT_TEST_OUTPUT=str(destination / 'build'))
            print('TIMER REGRESSION', name, flush=True)
            with (destination / 'run.log').open('w') as log:
                subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            record.write_text(json.dumps({'status': 'passed', 'config': row['config'],
                                         'mhz': row['mhz'], 'command': command}, indent=2) + '\n')
        verified = read(record)
        assert verified['status'] == 'passed' and verified['mhz'] == row['mhz']
        assert verified['config'] == row['config']
        interrupts.append({'name': name, 'record': str(record)})
    (root / 'final-validation.json').write_text(json.dumps({
        'status': 'passed', 'safety': safety, 'microbench_test': micro, 'interrupts': interrupts,
        'microbench_images_equal': True, 'microbench_train_rerun': False}, indent=2) + '\n')
    print('FINAL VALIDATION PASSED', decision['adopted'], flush=True)


if __name__ == '__main__':
    main()
