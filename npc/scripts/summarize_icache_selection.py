#!/usr/bin/env python3
"""Audit equal software/retirement and report measured cache selection points."""
import argparse
import json
from math import prod
from pathlib import Path

from select_icache import CONFIGS


def geometric_mean(values):
    return prod(values) ** (1 / len(values))


def load_run(path):
    data = json.loads(path.read_text())
    assert len(data['results']) == 6, path
    return data, {row['case']['name']: row for row in data['results']}


def compare(baseline, candidate):
    base_data, base = load_run(baseline)
    data, rows = load_run(candidate)
    assert base_data.get('memory_mode', 'cycle') == data.get('memory_mode', 'cycle'), 'Different memory models'
    assert all(base_data[k] == data[k] for k in ['latency_ns', 'beat_ns', 'random_stalls']), 'Different memory settings'
    assert set(base) == set(rows)
    cases = []
    for name, row in rows.items():
        reference = base[name]
        assert row['case']['hashes'] == reference['case']['hashes'], name
        for field in ['retired', 'all_retired', 'digest', 'checksum']:
            assert row['result'][field] == reference['result'][field], (name, field)
        cases.append({'name': name, 'cycles': row['result']['cycles'], 'seconds': row['seconds'],
                      'ipc': row['ipc'], 'cycle_ratio': row['result']['cycles'] / reference['result']['cycles'],
                      'time_ratio': row['seconds'] / reference['seconds'],
                      'counters': row['counters'],
                      'instruction_beat_ratio': row['counters']['i_beats'] / reference['counters']['i_beats']})
    return {'mhz': data['mhz'], 'memory_mode': data.get('memory_mode', 'cycle'), 'cases': cases,
            'cycle_ratio_gm': geometric_mean([c['cycle_ratio'] for c in cases]),
            'time_ratio_gm': geometric_mean([c['time_ratio'] for c in cases]),
            'time_ratio_worst': max(c['time_ratio'] for c in cases),
            'seconds_gm': geometric_mean([c['seconds'] for c in cases]),
            'architectural_audit_passed': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--run-label', default='dev-580')
    args = parser.parse_args()
    root = args.root.resolve()
    run_root = root / 'rtl' / args.run_label
    baseline = run_root / 'B0/results.json'
    result = {}
    for name in CONFIGS:
        path = run_root / name / 'results.json'
        if not path.exists() or len(json.loads(path.read_text())['results']) != 6:
            continue
        row = compare(baseline, path)
        qualified = root / 'ppa' / name / 'qualified.json'
        if qualified.exists():
            row['ppa'] = json.loads(qualified.read_text())
        result[name] = row
        print(name, f'cycles {row["cycle_ratio_gm"]:.5f}',
              f'max {row["time_ratio_worst"]:.5f}', row.get('ppa', {}).get('area_um2', 'STA pending'))
    (root / f'summary-{args.run_label}.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
