#!/usr/bin/env python3
"""Report absolute miss rates from saved functional I-cache model CSV files."""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bytes', type=int, default=1024)
    parser.add_argument('--ways', type=int, default=4)
    parser.add_argument('--line', type=int, default=32)
    parser.add_argument('--reference', type=Path,
                        help='Optional historical relative-miss summary to cross-check')
    args = parser.parse_args()
    geometry = (args.bytes, args.ways, args.line)
    cases, hashes = {}, {}
    for path in sorted(args.input.glob('*.csv')):
        with path.open() as stream:
            rows = list(csv.DictReader(stream))
        selected = [r for r in rows if tuple(int(r[k]) for k in
                    ('bytes', 'ways', 'line_bytes')) == geometry]
        if not selected:
            raise ValueError(f'No matching geometry: {path}')
        policies = {r['policy']: r for r in selected}
        if len(policies) != len(selected):
            raise ValueError(f'Duplicate policy: {path}')
        counts = {int(r['accesses']) for r in selected}
        if len(counts) != 1 or min(counts) <= 0:
            raise ValueError(f'Inconsistent access counts: {path}')
        for row in selected:
            if not 0 < int(row['misses']) <= int(row['accesses']):
                raise ValueError(f'Invalid miss count: {path}')
        cases[path.stem] = policies
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not cases:
        raise ValueError('No model CSV files found')
    policy_order = list(next(iter(cases.values())))
    if any(set(rows) != set(policy_order) for rows in cases.values()):
        raise ValueError('Policy sets differ across workloads')
    reference = None
    if args.reference:
        reference = json.loads(args.reference.read_text())['miss_ratio_gm']
        if set(reference) != set(policy_order):
            raise ValueError('Historical policy set differs')
    detail, summaries = [], []
    for policy in policy_order:
        misses = accesses = 0
        rates, ratios = [], []
        for name, rows in cases.items():
            row = rows[policy]
            count, miss = int(row['accesses']), int(row['misses'])
            rate = miss / count
            detail.append({'workload': name, 'policy': policy, 'accesses': count,
                           'misses': miss, 'miss_rate_percent': 100 * rate})
            misses += miss
            accesses += count
            rates.append(rate)
            ratios.append(miss / int(rows['plru']['misses']))
        relative = math.exp(sum(map(math.log, ratios)) / len(ratios))
        if reference is not None and not math.isclose(relative, reference[policy],
                                                     rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError(f'Historical relative summary differs: {policy}')
        summaries.append({'policy': policy, 'accesses': accesses, 'misses': misses,
                          'pooled_miss_rate_percent': 100 * misses / accesses,
                          'equal_workload_mean_miss_rate_percent': 100 * sum(rates) / len(rates),
                          'relative_miss_geomean_vs_plru': relative})
    args.output.mkdir(parents=True, exist_ok=True)
    for name, rows in [('per-workload.csv', detail), ('summary.csv', summaries)]:
        with (args.output / name).open('w') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    report = {'geometry': dict(zip(('bytes', 'ways', 'line_bytes'), geometry)),
              'measurement': 'Historical retired-PC functional model, cold cache; not RTL queries',
              'input_sha256': hashes, 'historical_relative_summary_matches':
              True if reference is not None else None, 'summary': summaries,
              'per_workload': detail}
    (args.output / 'absolute-miss-rates.json').write_text(json.dumps(report, indent=2) + '\n')
    lines = [f'# I-cache model: {args.bytes} B / {args.ways}-way / {args.line} B line', '',
             'Absolute miss rate = misses / retired-PC accesses. Each workload starts cold.',
             'Pooled rate uses summed misses and accesses; mean rate weights each workload equally.', '',
             '| Policy | Misses | Accesses | Pooled miss rate | Equal-workload mean |',
             '| --- | ---: | ---: | ---: | ---: |']
    for row in summaries:
        lines.append(f"| {row['policy']} | {row['misses']:,} | {row['accesses']:,} | "
                     f"{row['pooled_miss_rate_percent']:.6f}% | "
                     f"{row['equal_workload_mean_miss_rate_percent']:.6f}% |")
    lines += ['', '| Policy | ' + ' | '.join(cases) + ' |',
              '| --- | ' + ' | '.join(['---:'] * len(cases)) + ' |']
    for policy in policy_order:
        values = [100 * int(rows[policy]['misses']) / int(rows[policy]['accesses'])
                  for rows in cases.values()]
        lines.append('| ' + policy + ' | ' + ' | '.join(f'{x:.6f}%' for x in values) + ' |')
    (args.output / 'REPORT.md').write_text('\n'.join(lines) + '\n')
    print(f'PASS: {len(cases)} workloads, {len(policy_order)} policies; ' +
          ('historical relative results match' if reference is not None else 'absolute rates exported'))


if __name__ == '__main__':
    main()
