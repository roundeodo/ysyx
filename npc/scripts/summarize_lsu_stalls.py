#!/usr/bin/env python3
"""Summarize the recorded LSU diagnosis without treating stall counts as speedup."""
import argparse
import json
from pathlib import Path

NAMES = ['qsort', 'queen', 'bf', 'fib', 'sieve', '15pz', 'dinic', 'lzip', 'ssort', 'md5']


def load(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--legacy-reference', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    paths = {'rob256': root / 'rob-d256-detail-fixed/report.json',
             'rob1024': root / 'rob-d1024/report.json',
             'legacy256': args.legacy_reference.resolve() / 'report.json',
             'legacy1024': root / 'legacy-d1024/report.json'}
    reports = {name: load(path) for name, path in paths.items()}
    baseline = reports['rob256']
    rows = []
    for index, name in enumerate(NAMES):
        window = baseline['stalls']['subtests'][index]
        rows.append({'name': name, 'cycles': window['cycles'],
                     'lsu_capacity_cycles': window['categories']['lsu_capacity'],
                     'lsu_capacity_fraction': window['categories']['lsu_capacity'] / window['cycles'],
                     'dc_miss_busy_fraction': window['events']['dc_miss_busy'] / window['cycles'],
                     'blocked_ready_arithmetic_cycles': window['events']['ready_younger_with_rob_space'],
                     'shadow_same_line_cycles': window['events']['wait_same_line'],
                     'shadow_other_hit_cycles': window['events']['wait_other_line_hit'],
                     'shadow_other_miss_cycles': window['events']['wait_other_line_miss'],
                     'variant_cycles': {k: r['subtests'][index]['cycles'] for k, r in reports.items()}})
    comparisons = {}
    for first, second in [('rob256', 'rob1024'), ('legacy256', 'legacy1024'),
                          ('legacy256', 'rob256'), ('legacy1024', 'rob1024')]:
        comparisons[first + '_to_' + second] = {
            window: reports[second][window]['cycles'] / reports[first][window]['cycles'] - 1
            for window in ('total', 'scored')}
    directed = load(root / 'directed/report.json')
    schedules = {}
    for name, cases in directed['cases'].items():
        schedules[name] = {}
        for variant in ('rob', 'legacy'):
            a, b = cases[variant + '-loads-first'], cases[variant + '-arithmetic-first']
            schedules[name][variant] = {'loads_first_cycles': a['cycles'],
                                       'arithmetic_first_cycles': b['cycles'],
                                       'retired_each': a['retired'],
                                       'cycle_change_fraction': b['cycles'] / a['cycles'] - 1}
    summary = {'status': 'passed', 'scope': 'native MicroBench test; RV32IM; 680 MHz model; device 100 MHz',
               'image_sha256': baseline['image_sha256'],
               'no_functional_rtl_change': True,
               'native': {name: {k: r[k] for k in ('total', 'scored')} for name, r in reports.items()},
               'comparisons': comparisons, 'per_benchmark': rows,
               'baseline_stalls': {k: baseline['stalls'][k] for k in ('total', 'scored')},
               'directed_schedule_comparisons': schedules,
               'observer_equivalence': baseline['observer_equivalence'],
               'raw_report_index': {k: str(v) for k, v in paths.items()},
               'limits': ['No full train run', 'No new LSU, nonblocking cache, store buffer or multiple MSHRs implemented',
                          '1 KiB D-cache is cycle-sensitivity only; no new STA/area qualification',
                          'Overlapping events and repeated-ready cycles are not recoverable-cycle estimates',
                          'Software rescheduling demonstrates a mechanism, not the gain of an unimplemented queue',
                          'Directed legacy binary is the prior frozen standalone reference; native comparisons use final RTL'],
               'recommended_next_comparison': ['current baseline', 'two load contexts, same blocking cache',
                   'same contexts plus one-MSHR hit-under-miss', 'cache capacity control'],
               'defer': ['multiple misses until AXI arbiter/router and endpoint concurrency are addressed',
                         'posted stores until late-error and retirement semantics are specified']}
    (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(comparisons, indent=2))


if __name__ == '__main__':
    main()
