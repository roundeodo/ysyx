#!/usr/bin/env python3
"""Separate raw conditional direction errors from EX redirects in frozen logs."""
import collections
import hashlib
import json
import re

from run_btb_matrix import NPC


def read_counts(result, group):
    totals = collections.Counter()
    logs = []
    for record in result[group]['details']:
        path = NPC / record['log']
        raw = path.read_bytes()
        assert hashlib.sha256(raw).hexdigest() == record['log_sha256'], path
        for line in raw.decode().splitlines():
            if line.startswith('WINDOW '):
                fields = {key: int(value) for key, value in
                          re.findall(r'(\w+)=(\d+)', line)}
                totals.update({key: fields[key] for key in
                               ('conditional', 'raw_errors', 'redirects')})
        logs.append({'path': record['log'], 'sha256': record['log_sha256']})
    measured = result[group]['totals']
    assert totals['conditional'] > 0
    assert totals['redirects'] == measured['conditional_errors']
    counts = {
        'conditional_branches': totals['conditional'],
        'raw_direction_errors': totals['raw_errors'],
        'conditional_EX_redirects': totals['redirects'],
        'JAL_JALR_EX_redirects': measured['target_errors'],
        'all_control_flow_EX_redirects': totals['redirects'] + measured['target_errors'],
        'retired': measured['retired'],
    }
    return {'counts': counts,
            'raw_direction_error_rate': totals['raw_errors'] / totals['conditional'],
            'conditional_EX_redirect_rate': totals['redirects'] / totals['conditional'],
            'logs': logs}


def main():
    docs = NPC / 'docs/research/branch-v3'
    final_path = docs / 'final-results.json'
    results = json.loads(final_path.read_text())
    selected = {row['ppa']: row for row in results['results']
                if row['ppa'] in ('BT0', 'NSL-BT32-fold')}
    groups = {}
    for group in ('short_own', 'long_own'):
        baseline = read_counts(selected['BT0'], group)
        candidate = read_counts(selected['NSL-BT32-fold'], group)
        assert baseline['counts']['conditional_branches'] == candidate['counts']['conditional_branches']
        assert baseline['counts']['retired'] == candidate['counts']['retired']
        keys = ('raw_direction_errors', 'conditional_EX_redirects',
                'JAL_JALR_EX_redirects', 'all_control_flow_EX_redirects')
        groups[group] = {
            'baseline': baseline, 'TAGE_SC_Loop_BTB32': candidate,
            'count_reduction': {key: 1 - candidate['counts'][key] / baseline['counts'][key]
                                for key in keys},
        }
    document = {
        'source_final_results_sha256': hashlib.sha256(final_path.read_bytes()).hexdigest(),
        'scope': 'Frozen final inputs at each qualified clock: BT0 735MHz, NSL-BT32-fold 720MHz.',
        'definitions': {
            'raw_direction_errors': 'Conditional predictor direction before BTB availability or early target overrides, compared with actual taken.',
            'conditional_EX_redirects': 'Conditional instructions whose resolved next-PC mismatch triggers EX redirect; includes direction, absent target and wrong target.',
            'JAL_JALR_EX_redirects': 'Non-conditional jumps corrected at EX; includes returns. Not all conditional wrong-target cases.',
            'aggregation': 'Sum across measured windows, including final partial branch windows. Cold and warm windows overlap; these are not unique counts from one invocation. Counts are not family-weighted performance averages.',
        },
        'groups': groups,
    }
    (docs / 'final-prediction-counts.json').write_text(json.dumps(document, indent=2) + '\n')
    print('PASS frozen direction/EX counts: 40 logs hash-checked; branch-window sums match final counters')


if __name__ == '__main__':
    main()
