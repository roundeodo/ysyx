#!/usr/bin/env python3
"""Freeze a development-only decision, then evaluate untouched held software.

The objective and per-input guard are fixed before execution. Held results never
change the chosen configuration. Each family and input has equal weight.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import subprocess
import time
from explore_frontend import sha

CANDIDATES = ['B0', 'B64', 'B128', 'G64', 'G128', 'M64', 'S32', 'A32', 'R32']


def read_rows(root, label, name):
    path = root / 'rtl' / label / name / 'results.json'
    rows = json.loads(path.read_text())['results']
    return {row['case']['name']: row for row in rows}


def compare(rows, reference, mhz, base_mhz, area, base_area):
    assert rows.keys() == reference.keys()
    family = {}
    cases = {}
    for name, row in rows.items():
        baseline = reference[name]
        for key in ['retired', 'all_retired', 'digest', 'checksum']:
            assert row['result'][key] == baseline['result'][key], (name, key)
        ratio = row['result']['cycles'] / mhz / (baseline['result']['cycles'] / base_mhz)
        family.setdefault(row['case']['kind'], []).append(ratio)
        cases[name] = {
            'time_ratio': ratio,
            'cycles': row['result']['cycles'],
            'seconds': row['result']['cycles'] / (mhz * 1e6),
            'ipc': row['result']['retired'] / row['result']['cycles'],
            'i_beats': row['counters']['i_beats'],
            'd_transfer_cycles': row['counters']['d_beats'],
        }
    family = {name: math.exp(sum(map(math.log, values)) / len(values))
              for name, values in family.items()}
    time_ratio = math.exp(sum(map(math.log, family.values())) / len(family))
    return {'time_ratio_gm': time_ratio, 'area_ratio': area / base_area,
            'adp_ratio': area / base_area * time_ratio,
            'max_input_time_ratio': max(row['time_ratio'] for row in cases.values()),
            'families': family, 'cases': cases}


def execute(root, config, label, mhz, extra=()):
    output = root / 'rtl' / label / config
    assert not output.exists(), output
    subprocess.run(['python3', 'npc/scripts/followup_branch.py', 'run',
                    '--root', str(root), '--config', config, '--label', label,
                    '--mhz', str(mhz), *extra], check=True)


def parallel(jobs):
    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda args: execute(*args), jobs))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    deadline = time.monotonic() + 5 * 3600
    while not (root / 'own-clock-complete.json').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Own-clock matrix did not complete')
        time.sleep(10)
    ppa = {name: json.loads((root / 'ppa' / name / 'qualified.json').read_text())
           for name in CANDIDATES + ['B0current']}
    assert all(row['all_groups_passed'] for row in ppa.values())
    common_mhz = min(660, min(row['mhz'] for row in ppa.values()))
    common_label = 'dev-common'
    if common_mhz != 660:
        common_label += '-' + str(common_mhz)
        parallel([(root, name, common_label, common_mhz) for name in CANDIDATES])
    common_base = read_rows(root, common_label, 'B0')
    own_base = read_rows(root, 'dev-own', 'B0')
    development = {'common_mhz': common_mhz, 'common_label': common_label,
                   'objective': 'whole-core mapped area times family-balanced execution time',
                   'guard': 'no development input more than 3 percent slower at own legal clock',
                   'configurations': {}}
    for name in CANDIDATES:
        development['configurations'][name] = {
            'ppa': ppa[name],
            'common': compare(read_rows(root, common_label, name), common_base,
                              common_mhz, common_mhz, ppa[name]['area_um2'], ppa['B0']['area_um2']),
            'own': compare(read_rows(root, 'dev-own', name), own_base,
                           ppa[name]['mhz'], ppa['B0']['mhz'], ppa[name]['area_um2'], ppa['B0']['area_um2'])}
    eligible = {name: row for name, row in development['configurations'].items()
                if row['own']['max_input_time_ratio'] <= 1.03}
    winner = min(eligible, key=lambda name: eligible[name]['own']['adp_ratio'])
    report = root / 'development-summary.json'
    report.write_text(json.dumps(development, indent=2) + '\n')
    decision = {
        'utc': datetime.now(timezone.utc).isoformat(), 'selected': winner,
        'development_summary_sha256': sha(report),
        'image_manifest_sha256': sha(root / 'images/manifest.json'),
        'configuration_sha256': sha(root / 'configurations.json'),
        'held_configs': CANDIDATES,
        'held_policy': 'all frozen candidates; report all; never retune or choose another experimental candidate after held evaluation',
        'held_acceptance': 'development winner must also have held ADP below baseline and no held input over 3 percent slower; otherwise retain B0',
        'diagnostic_history_choice': 'G128 is the pre-held immediate-training model winner',
        'eligible': list(eligible),
        'integration_default': ppa['B0current'],
        'raw_input_hashes': {str(path.relative_to(root)): sha(path)
            for label in [common_label, 'dev-own'] for name in CANDIDATES
            for path in [root / 'rtl' / label / name / 'results.json']},
    }
    with (root / 'selection-freeze.json').open('x') as stream:
        stream.write(json.dumps(decision, indent=2) + '\n')
    print('SELECTION FROZEN', winner, flush=True)
    parallel([(root, name, 'held-own', ppa[name]['mhz'], ['--held']) for name in CANDIDATES])
    held_base = read_rows(root, 'held-own', 'B0')
    held = {name: compare(read_rows(root, 'held-own', name), held_base,
                         ppa[name]['mhz'], ppa['B0']['mhz'],
                         ppa[name]['area_um2'], ppa['B0']['area_um2']) for name in CANDIDATES}
    (root / 'held-summary.json').write_text(json.dumps(held, indent=2) + '\n')
    accepted = winner == 'B0' or (held[winner]['adp_ratio'] < 1 and
                                   held[winner]['max_input_time_ratio'] <= 1.03)
    recommendation = winner if accepted else 'B0'
    (root / 'held-decision.json').write_text(json.dumps({
        'development_choice': winner, 'held_accepted': accepted,
        'recommendation': recommendation, 'parameters_retuned_after_holdout': False}, indent=2) + '\n')
    print('HELD COMPLETE; frozen choice', winner, 'recommendation', recommendation, flush=True)
    # Sensitivity is reported separately, not used to replace the held decision.
    names = list(dict.fromkeys(['B0', 'G128', 'R32', winner]))
    modes = {'fast': ['--latency-ns', '20', '--beat-ns', '10'],
             'slow': ['--latency-ns', '200', '--beat-ns', '20'],
             'random': ['--random-stalls']}
    for mode, extra in modes.items():
        label = 'sensitivity-' + mode
        parallel([(root, name, label, common_mhz, extra) for name in names])
        reference = read_rows(root, label, 'B0')
        result = {name: compare(read_rows(root, label, name), reference,
                               common_mhz, common_mhz, ppa[name]['area_um2'], ppa['B0']['area_um2'])
                  for name in names}
        (root / (label + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    (root / 'evaluation-complete.json').write_text(json.dumps(
        {'selected': winner, 'recommendation': recommendation, 'common_mhz': common_mhz, 'held_families': 6,
         'power': 'not measured; accesses/traffic only',
         'old_cache_sta': 'not requalified; cache crossing is a functional cycle diagnostic'}, indent=2) + '\n')


if __name__ == '__main__':
    main()
