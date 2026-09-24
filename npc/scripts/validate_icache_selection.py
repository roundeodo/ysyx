#!/usr/bin/env python3
"""Freeze the completed dev ranking, then run declared common-clock/held checks."""
import argparse
import json
from pathlib import Path
import subprocess
import time

from explore_frontend import NPC
from select_icache import CONFIGS


def complete(path):
    return path.exists() and len(json.loads(path.read_text())['results']) == 6


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--memory-mode', choices=['cycle', 'physical'], default='physical')
    parser.add_argument('--wait-hours', type=float, default=8)
    args = parser.parse_args()
    root = args.root.resolve()
    deadline = time.monotonic() + args.wait_hours * 3600
    while not all((root / 'ppa' / name / 'qualified.json').exists() and
                  complete(root / 'rtl/dev-own' / name / 'results.json') and
                  complete(root / 'rtl/dev-580' / name / 'results.json') for name in CONFIGS):
        if time.monotonic() > deadline:
            raise RuntimeError('Development experiments remain incomplete')
        time.sleep(10)
    freeze = root / 'selection-freeze.json'
    if not freeze.exists():
        subprocess.run(['python3', str(NPC / 'scripts/rank_icache_selection.py'),
                        '--root', str(root), '--freeze'], check=True)
    selected = json.loads(freeze.read_text())
    common_mhz = min(580, *(row['mhz'] for row in selected['rows']))
    names = list(dict.fromkeys(name for name in ['B0', selected['selected'], selected['best_simple'],
                                               selected['matched_simple']] if name))
    protocol = {'memory_mode': args.memory_mode, 'frozen_selection': str(freeze), 'common_mhz': common_mhz, 'held_configs': names,
                'sensitivity': [[20, 10, False], [200, 20, False], [100, 10, True]],
                'held_inputs': [809, 1543], 'retune_allowed': False}
    (root / 'validation-protocol.json').write_text(json.dumps(protocol, indent=2) + '\n')

    def run(configs, label, extra):
        command = ['python3', str(NPC / 'scripts/select_icache.py'), '--output', str(root / 'rtl'),
                   '--images', str(root / 'images-v1'), '--host-opt', '2', '--no-trace', '--resume',
                   '--configs', *configs, '--memory-mode', args.memory_mode, '--run-label', label, *extra]
        print('VALIDATE', label, ' '.join(configs), flush=True)
        subprocess.run(command, check=True)

    # A shared clock at or below every measured pass point. 580 MHz remains an
    # earlier logical screening run for designs whose STA limit is below it.
    run(list(CONFIGS), f'dev-common-{common_mhz}', ['--mhz', str(common_mhz)])
    run(names, 'held-common', ['--held-out', '--mhz', str(common_mhz)])
    run(names, 'held-own', ['--held-out', '--qualified'])
    for first, beat, stalls in protocol['sensitivity']:
        extra = ['--held-out', '--qualified', '--latency-ns', str(first), '--beat-ns', str(beat)]
        if stalls:
            extra.append('--random-stalls')
        run(names, f'held-sensitivity-{first}-{beat}-{int(stalls)}', extra)
    run(list(dict.fromkeys(['B0', selected['selected']])), 'observer-off',
        ['--held-out', '--qualified', '--no-observer'])
    for name in list(dict.fromkeys(['B0', selected['selected']])):
        observed = json.loads((root / 'rtl/held-own' / name / 'results.json').read_text())['results']
        unobserved = json.loads((root / 'rtl/observer-off' / name / 'results.json').read_text())['results']
        assert all(a['result'] == b['result'] for a, b in zip(observed, unobserved)), name
    (root / 'validation-complete.json').write_text(json.dumps({
        'status': 'passed', 'protocol': protocol, 'observer_on_off_equal': True}, indent=2) + '\n')


if __name__ == '__main__':
    main()
