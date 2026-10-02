#!/usr/bin/env python3
"""Measure target/next-PC errors on the existing cold-ROI tier timing replay.

Only past resolutions train the tables. Outcomes select scoring events, never
lookup results. Baseline query order, timing and raw direction stay fixed.
"""
import collections
import hashlib
import json
from pathlib import Path

from targets import TargetTable
from trace_io import event_files, open_text, sha_uncompressed

NPC = Path(__file__).resolve().parents[2]
DOCS = NPC / 'docs/research/branch-v3'


def next_pc(pc, target, known_kind, raw_taken):
    if target is None or (known_kind == 1 and not raw_taken):
        return (pc + 4) & 0xffffffff
    return target


def measure(path):
    resolved, accepts = {}, {}
    with open_text(path) as stream:
        for line in stream:
            row = line.rstrip().split(',')
            if row[0] == 'R':
                resolved[int(row[1])] = row
            elif row[0] == 'A':
                accepts[int(row[1])] = int(row[2])
    tables = {n: TargetTable(n, 2) for n in (4, 16, 32)}
    kinds, pending = {}, {}
    counts = collections.Counter()
    with open_text(path) as stream:
        for line in stream:
            row = line.rstrip().split(',')
            if row[0] not in ('Q', 'R'):
                continue
            identity = int(row[1])
            if row[0] == 'Q':
                if identity not in resolved:
                    continue
                pc, cycle = int(row[3], 16), int(row[2])
                predictions = {n: table.lookup(pc) for n, table in tables.items()}
                pending[identity] = (pc, cycle, bool(int(row[5])),
                                     kinds.get(pc), predictions)
                continue
            pc, query_cycle, direction, known_kind, predictions = pending.pop(identity)
            assert pc == int(row[3], 16)
            target, actual_kind = int(row[4], 16), int(row[5])
            taken = bool(int(row[6]))
            actual_next = target if taken else (pc + 4) & 0xffffffff
            counts['branches'] += 1
            if actual_kind == 1:
                counts['conditional'] += 1
                counts['raw_direction_errors'] += direction != taken
            guesses = {f'single{n}': next_pc(pc, value, known_kind, direction)
                       for n, value in predictions.items()}
            for latency in (1, 2, 3, 4):
                arrived = query_cycle + latency < accepts[identity]
                value = predictions[32] if arrived and predictions[32] is not None else predictions[4]
                guesses[f'tier{latency}_before_fetch'] = next_pc(pc, value, known_kind, direction)
            # Eventual override diagnoses correctness alone, without a timing guarantee.
            value = predictions[32] if predictions[32] is not None else predictions[4]
            guesses['tier_eventual'] = next_pc(pc, value, known_kind, direction)
            for name, guess in guesses.items():
                counts[name + '_next_pc_errors'] += guess != actual_next
            if taken:
                counts['taken'] += 1
                for n, value in predictions.items():
                    counts[f'single{n}_target_correct'] += value == target
                    counts[f'single{n}_target_absent'] += value is None
                    counts[f'single{n}_target_wrong'] += value is not None and value != target
                if predictions[32] == target and predictions[4] != target:
                    counts['slow_corrects_fast_target'] += 1
                    counts['slow2_correct_before_fetch'] += query_cycle + 2 < accepts[identity]
            for table in tables.values():
                table.train(pc, target)
            kinds[pc] = actual_kind
    assert not pending
    return {'case': path.stem, 'event_sha256_uncompressed': sha_uncompressed(path),
            'counts': dict(counts)}


def main():
    records = []
    total = collections.Counter()
    for path in event_files(NPC / 'result/branch-v3/rtl/B0-opportunity'):
        row = measure(path)
        records.append(row)
        total.update(row['counts'])
        print('PASS tier accuracy', row['case'], flush=True)
    old = json.loads((DOCS / 'timing-opportunities.json').read_text())
    reference = collections.Counter()
    for row in old['records']:
        reference.update(row['tier_fixed_event_M1'])
    assert total['slow_corrects_fast_target'] == reference['late_target_correct']
    assert total['slow2_correct_before_fetch'] == reference['late2_before_fetch_accept']
    rates = {name: value / total['branches'] for name, value in total.items()
             if name.endswith('_next_pc_errors')}
    target_rates = {f'single{n}': total[f'single{n}_target_correct'] / total['taken']
                    for n in (4, 16, 32)}
    document = {
        'scope': '10 development proxy inputs; same B0-opportunity query/accept/resolve timing; cold ROI tables.',
        'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'limits': [
            'This is fixed-event M1 replay, not new CPU execution or RTL equivalence.',
            'The raw baseline BHT direction is held fixed. No candidate-specific history or wrong paths.',
            'Full-PC target tables use two ways and round-robin replacement; all resolutions train.',
            'Each tier has 4+32 entries (36 total); it is not the same capacity as a single32 table.',
            'before_fetch only applies the slow override when it precedes the recorded fetch acceptance; later EX opportunities are excluded.',
            'eventual has no latency guarantee and is not a deployable performance result.',
            'Missing target counts as incorrect target availability for a taken branch.',
            'No predecode/prefill, region table or joint compressed-TAGE accuracy is claimed.',
        ],
        'counts': dict(total), 'next_pc_error_rates': rates,
        'taken_target_correct_rates': target_rates, 'records': records,
    }
    (DOCS / 'tier-accuracy.json').write_text(json.dumps(document, indent=2) + '\n')
    print('TOTAL', json.dumps(dict(total)), flush=True)
    print('NEXT_PC_ERROR_RATES', json.dumps(rates), flush=True)
    print('TAKEN_TARGET_CORRECT_RATES', json.dumps(target_rates), flush=True)


if __name__ == '__main__':
    main()
