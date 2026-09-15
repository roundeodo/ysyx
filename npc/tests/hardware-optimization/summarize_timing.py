#!/usr/bin/env python3
"""Keep host time, benchmark time and calibrated CPU time distinct."""
import argparse
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('artifacts', type=Path)
args = parser.parse_args()
root = args.artifacts.resolve()
results = {}
variants = ['baseline', 'merge-decode', 'lsu-completion-issue',
            'lsu-completion-issue-calibrated-820']
for variant in variants:
    directory = root / variant
    calibrated = 'calibrated' in variant
    timer_mhz = 820 if calibrated else 100
    ratio_scaled = 8396 if calibrated else 3037
    result = {
        'timer_cpu_mhz': timer_mhz, 'sta_constraint_mhz': 820,
        'device_mhz': 100, 'delay_ratio_scaled': ratio_scaled, 'delay_scale': 1024,
        'delay_ratio': ratio_scaled / 1024,
        'calibrated_for_820mhz': calibrated,
    }
    for scale in ['test', 'train']:
        measurement = directory / f'{scale}.json'
        if not measurement.exists():
            result[scale] = {'status': 'pending'}
            continue
        counters = json.loads(measurement.read_text())
        # An O3 log may still be running its parity check. Use it only after its result exists.
        stem = f'{scale}-o3' if (directory / f'{scale}-o3.json').exists() else scale
        log = (directory / f'{stem}.log').read_text(errors='replace')
        times = re.findall(r'(Scored|Total)\s+time:\s*([\d.]+) ms', log)
        if set(key for key, _ in times) != {'Scored', 'Total'}:
            raise SystemExit(f'Missing complete benchmark times: {variant}/{scale}')
        entry = {'status': counters['status'], 'cycles': counters['cycles'],
                 'instructions': counters['retired_instructions'], 'ipc': counters['ipc'],
                 'pmu_window_seconds_at_timer_rate': counters['cycles'] / (timer_mhz * 1e6),
                 **{f'{key.lower()}_seconds': float(value) / 1000 for key, value in times}}
        host_file = directory / f'{stem}-run.json'
        if host_file.exists():
            host = json.loads(host_file.read_text())
            entry['host_wall_seconds'] = host.get('host_wall_seconds', host.get('wall_seconds'))
        if calibrated:
            entry['model_execution_seconds'] = entry['pmu_window_seconds_at_timer_rate']
        result[scale] = entry
    results[variant] = result
(root / 'timing-summary.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
