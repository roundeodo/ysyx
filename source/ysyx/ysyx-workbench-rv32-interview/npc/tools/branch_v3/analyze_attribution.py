#!/usr/bin/env python3
"""Separate direction, target availability and late recovery on actual RTL events.

Pair architectural branch order, never query IDs or clock positions across runs.
Cycle classes describe observed occupancy; they are not causal stall penalties.
"""
import collections
import json
import re
from pathlib import Path

from summarize import means, read_records
from trace_io import open_text, sha_uncompressed

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'
DOCS = NPC / 'docs/research/branch-v3'
CONFIGURATIONS = {
    'B0': 'B0-victim',
    'TAGE': 'N0-victim',
    'TAGE_SC_Loop': 'NSL-victim',
    'BHT_early_direct': 'E0-victim',
    'TAGE_early_direct_RAS': 'NER0-victim',
    'TAGE_SC_Loop_early_direct_RAS': 'NSLER-victim',
}
CYCLE_KEYS = ('cycles', 'retired', 'data_wait', 'frontend_wait', 'other',
              'misses', 'i_beats', 'd_beats')


def load_events(path):
    resolved, early, committed = [], {}, set()
    with open_text(path) as stream:
        for line in stream:
            row = line.rstrip().split(',')
            if row[0] == 'C':
                committed.add(int(row[1]))
            elif row[0] == 'E':
                early[int(row[1])] = int(row[3], 16)
            elif row[0] == 'R':
                resolved.append(row)
    branches, counts, windows = [], collections.Counter(), []
    window = collections.Counter()
    first_cycle = None
    for row in resolved:
        identity, cycle = int(row[1]), int(row[2])
        assert identity in committed, (path, identity, 'resolved event did not retire')
        pc, target = int(row[3], 16), int(row[4], 16)
        kind, taken = int(row[5]), bool(int(row[6]))
        raw_taken, hit, late = bool(int(row[7])), bool(int(row[8])), bool(int(row[10]))
        label = {1: 'conditional', 2: 'jal', 3: 'jalr'}[kind]
        counts[label] += 1
        counts[label + '_late_redirect'] += late
        counts[label + '_early_redirect'] += identity in early
        if identity in early:
            counts[label + '_early_correct'] += early[identity] == (target if taken else (pc + 4) & 0xffffffff)
        branches.append((pc, target, kind, taken))
        if kind != 1:
            continue
        raw_correct = raw_taken == taken
        features = {
            'raw_direction_errors': not raw_correct,
            'btb_absent': not hit,
            'raw_correct_taken_without_btb': raw_correct and taken and not hit,
            'raw_correct_taken_without_btb_still_late': raw_correct and taken and not hit and late,
            'raw_correct_with_btb_still_late': raw_correct and hit and late,
            'conditional_late_redirect': late,
            'wrong_direction_masked_by_no_target': not raw_correct and not hit and not late,
        }
        for name, value in features.items():
            if name != 'conditional_late_redirect':
                counts[name] += value
            window[name] += value
        if first_cycle is None:
            first_cycle = cycle
        window['conditional'] += 1
        if window['conditional'] == 8192:
            windows.append({**window, 'first_resolve_cycle': first_cycle, 'last_resolve_cycle': cycle})
            window, first_cycle = collections.Counter(), None
    if window:
        windows.append({**window, 'first_resolve_cycle': first_cycle,
                        'last_resolve_cycle': int(resolved[-1][2]), 'partial': True})
    return branches, dict(counts), windows


def main():
    measured = read_records()
    baseline = {}
    records, aggregates = [], {}
    for configuration, prefix in CONFIGURATIONS.items():
        selected = [row for row in measured if row['run'] in
                    (prefix + '-dev', prefix + '-stream-dev-700')]
        assert len(selected) == 14, (configuration, len(selected))
        counts, cycles, details, walltimes = collections.Counter(), collections.Counter(), [], []
        for row in selected:
            path = ROOT / 'rtl' / row['run'] / (row['case'] + '.events')
            branch_order, observed, windows = load_events(path)
            key = (row['dataset'], row['case'])
            if configuration == 'B0':
                baseline[key] = (branch_order, row)
            reference_order, reference = baseline[key]
            assert branch_order == reference_order, (configuration, key, 'branch stream changed')
            assert row['retired'] == reference['retired']
            assert all(row[k] == reference[k] for k in ('image', 'mhz', 'latency_ns', 'seed', 'random_stalls'))
            assert observed['conditional_late_redirect'] == row['conditional_errors']
            assert observed['jal_late_redirect'] + observed['jalr_late_redirect'] == row['target_errors']
            assert sum(row[k] for k in ('retired', 'data_wait', 'frontend_wait', 'other')) == row['cycles']
            log = (NPC / row['log']).read_text()
            wall = float(re.search(r'walltime ([0-9.]+) s', log)[1])
            walltimes.append(wall)
            counts.update(observed)
            cycles.update({k: row[k] for k in CYCLE_KEYS})
            details.append({'family': row['family'], 'time_ratio': row['cycles'] / reference['cycles']})
            records.append({'configuration': configuration, 'case': row['case'],
                            'dataset': row['dataset'], 'counts': observed,
                            'cycles': {k: row[k] for k in CYCLE_KEYS}, 'cpu_seconds': row['seconds'],
                            'host_wall_seconds_with_events': wall, 'log': row['log'],
                            'log_sha256': row['log_sha256'], 'binary_sha256': row['binary_sha256'],
                            'event_path': str(path.relative_to(NPC)),
                            'event_sha256_uncompressed': sha_uncompressed(path),
                            'conditional_windows_8192': windows})
        aggregates[configuration] = {
            'counts': dict(counts), 'cycles': dict(cycles),
            'paired_time': means(details),
            'host_wall_seconds_with_events': {'sum': sum(walltimes), 'min': min(walltimes), 'max': max(walltimes)},
        }
        print('PASS attribution', configuration, 'raw errors', counts['raw_direction_errors'],
              'late', counts['conditional_late_redirect'], flush=True)
    document = {
        'scope': '14 development windows, seven equally weighted families, 700MHz, 100ns/10ns AXI',
        'limits': [
            'No train. Small kernels and short request streams do not establish application representativeness.',
            'Same-frequency cycle diagnostics do not grant 700MHz STA qualification to every configuration.',
            'BTB absent is recorded at the original query; an early redirect may later supply the target.',
            'Raw direction errors differ from effective next-PC errors; no-target not-taken may mask an error.',
            'Occupancy classes are mutually exclusive, but frontend_wait includes cache and recovery effects.',
            'Host walltime includes event/trace writing and machine load; no cross-build simulation-speed claim.',
            '8192-event windows expose variation; their existence is not proof of warmup convergence.',
        ],
        'configurations': CONFIGURATIONS, 'aggregates': aggregates, 'records': records,
    }
    (DOCS / 'attribution.json').write_text(json.dumps(document, indent=2) + '\n')


if __name__ == '__main__':
    main()
