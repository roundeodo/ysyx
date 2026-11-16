#!/usr/bin/env python3
"""Export measured branch windows; a long input is not proof of convergence."""
import csv
import json
import re

from run_btb_matrix import NPC, ROOT
from run_large_btb_matrix import POINTS


def main():
    curves, summaries = [], []
    for name, (_, mhz) in POINTS.items():
        folder = ROOT/'rtl'/f'{name}-paired-long-{mhz}'
        assert (folder/'index.json').exists(), name
        for record in json.loads((folder/'index.json').read_text()):
            text = (folder/(record['name']+'.log')).read_text()
            windows = [dict((key, int(value)) for key, value in re.findall(r'(\w+)=(\d+)', line))
                       for line in text.splitlines() if line.startswith('WINDOW ')]
            cumulative = 0
            for row in windows:
                cumulative += row['conditional']
                curves.append({'configuration': name, 'case': record['name'], 'mhz': mhz,
                               'window': row['index'], 'cumulative_conditional': cumulative,
                               **{key: row[key] for key in ['conditional', 'raw_errors', 'missing', 'redirects', 'first', 'last']},
                               'partial': row.get('partial', 0)})
            phases = []
            for quarter in range(4):
                selected = windows[len(windows)*quarter//4:len(windows)*(quarter+1)//4]
                totals = {key: sum(row[key] for row in selected)
                          for key in ['conditional', 'raw_errors', 'missing', 'redirects']}
                phases.append({**totals, 'raw_error_rate': totals['raw_errors']/totals['conditional'],
                               'conditional_redirect_rate': totals['redirects']/totals['conditional']})
            footprint = next(line for line in text.splitlines() if line.startswith('FOOTPRINT '))
            summaries.append({'name': name, 'case': record['name'], 'windows': len(windows),
                              'conditional_events': cumulative, 'quarters': phases,
                              'footprint': dict((key, int(value)) for key, value in re.findall(r'(\w+)=(\d+)', footprint))})
    docs = NPC/'docs/research/branch-v3'
    with (docs/'learning-curves.csv').open('w') as file:
        writer = csv.DictWriter(file, fieldnames=list(curves[0]))
        writer.writeheader();writer.writerows(curves)
    (docs/'learning-curves.json').write_text(json.dumps({
        'window_definition': '8192 resolved conditional branches; final partial window retained; first/last are CPU cycles',
        'scope': 'same-image passive cold/warm windows, 128 distinct requests; quarters describe phases, not a convergence test',
        'limits': 'missing counts all conditional BTB absences, including intentionally unadmitted not-taken branches; not useful-target starvation. Inputs differ across phases; changes in error rate cannot all be assigned to training.',
        'records': summaries}, indent=2)+'\n')
    print('EXPORTED learning curves', len(curves), 'windows')


if __name__ == '__main__':
    main()
