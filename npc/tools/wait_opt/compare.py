#!/usr/bin/env python3
"""Summarize measured cycles and PPA without rescaling device latency."""
import json
import math
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
DATA = NPC / 'docs/verification/data/wait-opt-20261002'


def read(path):
    return json.loads(path.read_text())


def summarize(name):
    folder = DATA / name
    ppa = folder / 'ppa'
    result = {'name': name}
    if ppa.exists():
        result.update(read(ppa / 'qualified.json'))
        timing = read(ppa / 'timing.json')
        result['at_700'] = next(entry for entry in timing if entry['mhz'] == 700)
    native = folder / 'native/report.json'
    if native.exists():
        report = read(native)
        baseline = read(DATA / 'baseline/native/report.json')
        result['native'] = {'cpu_mhz': report['cpu_mhz']}
        for window in ['total', 'scored', 'whole_program']:
            result['native'][window] = report[window]
            result['native'][window]['cycles_change_pct'] = 100 * (
                report[window]['cycles'] / baseline[window]['cycles'] - 1)
        # Use the actual simulation's frequency and cycles, not 700 MHz cycles
        # divided by another frequency: the memory model depends on frequency.
        result['native']['total_cycle_time_change_pct'] = 100 * (
            report['total']['cycle_seconds'] / baseline['total']['cycle_seconds'] - 1)
    result['proxy'] = {}
    for suite in ['dev', 'streams']:
        path = folder / 'proxy' / suite / 'results.json'
        if not path.exists():
            continue
        measured = read(path)
        baseline = read(DATA / 'baseline/proxy' / suite / 'results.json')
        reference = {entry['case']['name']: entry for entry in baseline['results']}
        rows = []
        for entry in measured['results']:
            old = reference[entry['case']['name']]
            assert entry['result']['checksum'] == old['result']['checksum']
            ratio = entry['result']['cycles'] / old['result']['cycles']
            rows.append({
                'name': entry['case']['name'], 'cycles': entry['result']['cycles'],
                'cycles_ratio': ratio,
                'time_ratio': ratio * baseline['mhz'] / measured['mhz'],
                'i_beats_change': entry['counters']['i_beats'] - old['counters']['i_beats'],
                'd_beats_change': entry['counters']['d_beats'] - old['counters']['d_beats'],
            })
        result['proxy'][suite] = {
            'mhz': measured['mhz'], 'cases': rows,
            'cycles_geomean_change_pct': 100 * (
                math.prod(row['cycles_ratio'] for row in rows) ** (1 / len(rows)) - 1),
            'time_geomean_change_pct': 100 * (
                math.prod(row['time_ratio'] for row in rows) ** (1 / len(rows)) - 1),
        }
    return result


if __name__ == '__main__':
    names = ['baseline', 'dirty-dispatch', 'frontend-restart', 'frontend-ex-restart',
             'cache-handoff', 'array-forward', 'combined', 'final-715']
    result = {
        'selected': 'array-forward', 'default_mhz': 700,
        'tested_higher_mhz': 715,
        'limitations': ['post-synthesis STA only', 'no train rerun',
                        'proxy physical model and native SoC results are separate'],
        'variants': [summarize(name) for name in names],
    }
    (DATA / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
