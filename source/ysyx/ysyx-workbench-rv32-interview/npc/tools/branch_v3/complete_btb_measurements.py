#!/usr/bin/env python3
"""Complete declared controls; never choose parameters using the final partition."""
import argparse
import json
import subprocess
import sys

from run_btb_matrix import NPC, ROOT, TOOL, CONFIGS
from run_btb_extended import CONFIGS as JOINT


def invoke(script, *arguments):
    subprocess.run([sys.executable, str(TOOL/script), *map(str, arguments)], check=True)


def run_pair(name, label, mhz, *, validation=False, latency=100, stalls=0, seed=97531):
    for suffix, images in [('dev', 'images'),
                           ('streams', 'streams-validation' if validation else 'streams-development')]:
        destination = f'{name}-{label}-{suffix}'
        if (ROOT/'rtl'/destination/'index.json').exists():
            continue
        arguments = ['run', '--name', name, '--label', destination, '--images', ROOT/images,
                     '--compact', '--mhz', mhz, '--latency-ns', latency,
                     '--random-stalls', stalls, '--seed', seed]
        if validation and suffix == 'dev':
            arguments.append('--validation')
        invoke('run_core.py', *arguments)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['common', 'validation', 'sensitivity'])
    parser.add_argument('--names', nargs='+', help='Execute a subset of the already frozen matrix')
    args = parser.parse_args()
    names = [*CONFIGS, *[name for name in JOINT if not name.endswith('-long')]]
    for matrix in ['btb-ablation-extension.json', 'btb-direction-extension.json',
                   'btb-simple-direction-extension.json']:
        names.extend(json.loads((NPC/'docs/research/branch-v3'/matrix).read_text()))
    # Frozen from development results: cheap alternatives, target capacity, TAGE
    # ablation, plus the previous early-target and return-identification controls.
    shortlist = ['BT0', 'BT16-admit', 'BT16-rrip-all', 'BT16-way4-rrip',
                 'BT32-select-fold', 'TAGE-BT32-fold', 'NSL-BT32-fold',
                 'H2E-victim', 'R0-victim']
    record = {'candidates': shortlist, 'split': 'validation, never final',
              'reason': 'development cost/time points and earlier strong simple target controls',
              'metric': 'equal families, own qualified frequency; final eligibility requires <=3% per-input regression',
              'sensitivity': {'common_mhz': 520, 'latency_ns': [20, 200],
                              'random_stalls': 1, 'seeds': [191, 811]}}
    freeze = NPC/'docs/research/branch-v3/btb-validation-contract.json'
    if freeze.exists():
        assert json.loads(freeze.read_text()) == record
    else:
        freeze.write_text(json.dumps(record, indent=2)+'\n')
    if args.action == 'common':
        if args.names:
            assert set(args.names) <= set(names)
            names = args.names
        for name in names:
            # Missing qualification is pending, not failure or presumed pass.
            if not (ROOT/'ppa'/name/'qualified.json').exists():
                print('PENDING PPA', name, flush=True)
                continue
            invoke('probe_ppa.py', name, '--mhz', 400)
            if not json.loads((ROOT/'ppa'/name/'probe-400.json').read_text())['passed']:
                print('UNQUALIFIED common clock', name, flush=True)
                continue
            run_pair(name, 'common-400', 400)
    else:
        if args.names:
            assert set(args.names) <= set(shortlist)
            shortlist = args.names
        for name in shortlist:
            point = ROOT/'ppa'/name
            qualified_file = next(point/file for file in
                                  ['qualified-btb-fine.json', 'qualified-fine.json', 'qualified.json']
                                  if (point/file).exists())
            qualified = json.loads(qualified_file.read_text())
            if args.action == 'validation':
                run_pair(name, f'validation-{qualified["mhz"]}', qualified['mhz'], validation=True)
            else:
                invoke('probe_ppa.py', name, '--mhz', 520)
                assert json.loads((point/'probe-520.json').read_text())['passed']
                for latency in [20, 200]:
                    run_pair(name, f'sensitivity-{latency}ns-520', 520, latency=latency)
                for seed in [191, 811]:
                    run_pair(name, f'sensitivity-random-{seed}-520', 520, stalls=1, seed=seed)
            print('COMPLETE', args.action, name, flush=True)


if __name__ == '__main__':
    main()
