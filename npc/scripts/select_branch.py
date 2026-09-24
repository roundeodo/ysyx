#!/usr/bin/env python3
"""Freeze development choices, then evaluate held inputs without retuning."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
from pathlib import Path
import time

from qualify_branch_runs import check_architecture, digest, read, run_cases


def ratios(reference, measured):
    baseline = {row['case']['name']: row for row in reference['results']}
    return {row['case']['name']: row['seconds'] / baseline[row['case']['name']]['seconds']
            for row in measured['results']}


def geometric(values):
    return math.prod(values) ** (1 / len(values))


def summarize(root, name, label):
    baseline = read(root / 'rtl' / label / 'B0/results.json')
    measured = read(root / 'rtl' / label / name / 'results.json')
    check_architecture(baseline, measured)
    times = ratios(baseline, measured)
    area = read(root / 'ppa' / name / 'qualified.json')['area_um2']
    baseline_area = read(root / 'ppa/B0/qualified.json')['area_um2']
    errors = lambda row: sum(row['counters'][key] for key in ['btb_missing', 'direction', 'target'])
    cases = []
    for row, base in zip(measured['results'], baseline['results']):
        assert row['case']['name'] == base['case']['name']
        cases.append({'name': row['case']['name'], 'cycles': row['result']['cycles'],
                      'seconds': row['seconds'], 'ipc': row['ipc'],
                      'errors': errors(row), 'i_beats': row['counters']['i_beats'],
                      'd_transfer_cycles': row['counters']['d_beats'],
                      'lookup_queries': row['counters']['queries'],
                      'frontend_wait': row['counters']['frontend_wait'],
                      'data_wait': row['counters']['data_wait'],
                      'time_ratio': times[row['case']['name']],
                      'i_beats_ratio': row['counters']['i_beats'] / base['counters']['i_beats']})
    return {'name': name, 'mhz': measured['mhz'], 'area_um2': area,
            'time_ratio_gm': geometric(list(times.values())), 'max_time_ratio': max(times.values()),
            'adp_ratio': area / baseline_area * geometric(list(times.values())),
            'cases': cases}


def freeze(root):
    path = root / 'selection-freeze.json'
    if path.exists():
        saved = read(path)
        for name, expected in saved['inputs'].items():
            assert digest(root / name) == expected, name
        return saved
    qualification = read(root / 'qualified-runs.json')
    configs = read(root / 'configurations.json')
    rows = [summarize(root, name, 'dev-own') for name in qualification['names']]
    allowed = [row for row in rows if row['max_time_ratio'] <= 1.03]
    simple = min((row for row in allowed if configs[row['name']]['policy'] != 2), key=lambda r: r['adp_ratio'])
    rrip = min((row for row in rows if configs[row['name']]['policy'] == 2), key=lambda r: r['adp_ratio'])
    simple_runs = read(root / 'rtl/dev-own' / simple['name'] / 'results.json')
    eligible = [row for row in allowed if max(ratios(simple_runs, read(
        root / 'rtl/dev-own' / row['name'] / 'results.json')).values()) <= 1.03]
    selected = min(eligible, key=lambda r: r['adp_ratio'])
    inputs = [Path('configurations.json'), Path('qualified-runs.json')]
    for name in qualification['names']:
        inputs += [Path('rtl/dev-own') / name / 'results.json', Path('rtl/dev-common') / name / 'results.json',
                   Path('ppa') / name / 'qualified.json']
    saved = {'criterion': 'whole-core area times equal-weight geometric mean physical-memory execution time',
             'development_single_case_limit': 1.03, 'held_single_case_limit': 1.03,
             'candidate': selected['name'], 'best_simple': simple['name'], 'best_rrip': rrip['name'],
             'fallback_order': [simple['name'], 'B0'], 'rows': rows,
             'common_mhz': qualification['common_mhz'],
             'held_names': list(dict.fromkeys(['B0', selected['name'], simple['name'], rrip['name']])),
             'inputs': {str(p): digest(root / p) for p in inputs},
             'policy': 'Do not change candidates or parameters after any held performance is observed.'}
    with path.open('x') as stream:
        stream.write(json.dumps(saved, indent=2) + '\n')
    print('FROZEN', saved['candidate'], 'simple', saved['best_simple'], 'RRIP', saved['best_rrip'], flush=True)
    return saved


def validate(root, frozen, jobs=2):
    names = frozen['held_names']
    for label in ['held-own', 'held-common']:
        def measure(name):
            mhz = read(root / 'ppa' / name / 'qualified.json')['mhz'] if label == 'held-own' else frozen['common_mhz']
            return run_cases(root, name, label, mhz, held=True)

        with ThreadPoolExecutor(max_workers=jobs) as pool:
            measured = list(pool.map(measure, names))
        for data in measured:
            check_architecture(read(root / 'rtl' / label / 'B0/results.json'), data)
    rows = {name: summarize(root, name, 'held-own') for name in names}
    simple, candidate = frozen['best_simple'], frozen['candidate']
    simple_ok = rows[simple]['adp_ratio'] <= 1 and rows[simple]['max_time_ratio'] <= 1.03
    chosen, reason = ('B0', 'Frozen simple fallback did not pass held guardrails.')
    if simple_ok:
        chosen, reason = simple, 'Frozen simple configuration passed held guardrails.'
    if candidate != simple:
        against_simple = ratios(read(root / 'rtl/held-own' / simple / 'results.json'),
                                read(root / 'rtl/held-own' / candidate / 'results.json'))
        candidate_ok = (rows[candidate]['adp_ratio'] < min(1, rows[simple]['adp_ratio']) and
                        rows[candidate]['max_time_ratio'] <= 1.03 and max(against_simple.values()) <= 1.03)
        if candidate_ok:
            chosen, reason = candidate, 'Frozen candidate beats baseline and simple ADP and passes both per-case guards.'
    decision = {'adopted_for_evaluation': chosen, 'default_changed': False, 'reason': reason,
                'held_rows': rows, 'freeze_sha256': digest(root / 'selection-freeze.json')}
    path = root / 'decision.json'
    if path.exists():
        assert read(path) == decision
    else:
        path.write_text(json.dumps(decision, indent=2) + '\n')
    # Sensitivity and observer checks are diagnostics, never a second tuning set.
    followup_names = list(dict.fromkeys(['B0', chosen, simple, frozen['best_rrip']]))
    conditions = [('held-fast', 20, 10, False, True), ('held-slow', 200, 20, False, True),
                  ('held-random', 100, 10, True, True), ('held-observer-off', 100, 10, False, False)]

    def measure_sensitivity(item):
        name, (label, latency, beat, stalls, observer) = item
        mhz = read(root / 'ppa' / name / 'qualified.json')['mhz']
        reference = read(root / 'rtl/held-own' / name / 'results.json')
        data = run_cases(root, name, label, mhz, held=True, latency=latency, beat=beat,
                         random_stalls=stalls, observer=observer)
        check_architecture(reference, data)
        if not observer:
            for base, row in zip(reference['results'], data['results']):
                assert base['result'] == row['result'], (name, row['case']['name'])

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        list(pool.map(measure_sensitivity, [(name, condition) for name in followup_names for condition in conditions]))
    (root / 'validation-complete.json').write_text(json.dumps({
        'status': 'passed', 'observer_on_off_exact': True, 'decision_sha256': digest(path),
        'names': followup_names}, indent=2) + '\n')
    print('HELD VALIDATION', chosen, reason, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--wait-hours', type=float, default=12)
    parser.add_argument('--jobs', type=int, choices=[1, 2], default=2)
    args = parser.parse_args()
    root = args.root.resolve()
    deadline = time.monotonic() + args.wait_hours * 3600
    while not (root / 'qualified-runs.json').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Qualified development results are incomplete; no selection made.')
        time.sleep(10)
    validate(root, freeze(root), args.jobs)


if __name__ == '__main__':
    main()
