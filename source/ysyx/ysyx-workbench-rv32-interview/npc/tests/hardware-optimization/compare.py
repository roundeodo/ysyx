#!/usr/bin/env python3
"""Compare only completed, matching-workload measurements; keep train pending explicit."""
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
summary = json.loads((root / 'summary.json').read_text())
baseline = summary['baseline']
comparison = {}
for name, result in summary.items():
    if name == 'baseline':
        continue
    entry = {'status': 'awaiting_train', 'workload': 'same archived train.bin'}
    if 'ppa' in result:
        entry['area_change_percent'] = 100 * (result['ppa']['area_um2'] / baseline['ppa']['area_um2'] - 1)
        entry['timing_passed_820mhz'] = result['ppa']['timing_passed']
        if not result['ppa']['timing_passed']:
            entry['status'] = 'rejected_at_820mhz'
    for scale in ['test', 'train']:
        before, after = baseline[scale], result[scale]
        if before.get('status') != 'passed' or after.get('status') != 'passed':
            continue
        if before['retired_instructions'] != after['retired_instructions']:
            raise SystemExit(f'{name}/{scale}: instruction count changed; investigate before accepting')
        entry[scale] = {
            'ipc_change_percent': 100 * (after['ipc'] / before['ipc'] - 1),
            'cycle_reduction': before['cycles'] - after['cycles'],
            'cycle_change_percent': 100 * (after['cycles'] / before['cycles'] - 1),
        }
    if 'train' in entry and 'ppa' in result and entry.get('timing_passed_820mhz'):
        entry['status'] = ('meets_area_and_train_ipc_targets'
                           if entry['area_change_percent'] < 0 and entry['train']['ipc_change_percent'] > 0
                           else 'does_not_meet_both_targets')
    comparison[name] = entry
(root / 'comparison.json').write_text(json.dumps(comparison, indent=2) + '\n')
print(json.dumps(comparison, indent=2))
