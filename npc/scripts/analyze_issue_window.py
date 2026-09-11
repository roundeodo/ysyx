#!/usr/bin/env python3
"""Validate fixed-image MicroBench measurements and export observed issue categories."""
import argparse
import json
from pathlib import Path
import re
from record_performance import parse_measurement_window

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('log', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
log = args.log.read_text(errors='replace')
if 'MicroBench PASS' not in log or 'HIT GOOD TRAP' not in log:
    raise SystemExit('Missing benchmark PASS / GOOD TRAP')
cycles, instructions, ipc = parse_measurement_window(log)
windows = re.findall(r'ISSUE_WINDOW end=(\d+) sampled_cycles=(\d+) cumulative_observed_cycles=(\d+)', log)
if not windows:
    raise SystemExit('No observation windows found')
previous_cycles = 0
for index, (number, sampled, observed) in enumerate(windows, 1):
    if int(number) != index or int(observed) - previous_cycles != int(sampled):
        raise SystemExit(f'CSR sample / retirement window mismatch: {number, sampled, observed}')
    previous_cycles = int(observed)
match = re.findall(r'ISSUE_WINDOW total (.*)', log)
if len(match) != 1:
    raise SystemExit('Expected one final observer summary')
counts = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', match[0])}
category_names = ['issue', 'recovery', 'lsu_block', 'result_block', 'execute_wait', 'raw', 'serial', 'delivery_gap']
if (counts['active'] != 0 or counts['windows'] != len(windows) or
        counts['cycles'] != cycles or previous_cycles != cycles or
        sum(counts[key] for key in category_names) != cycles):
    raise SystemExit('Window totals / category partition / PMU total mismatch')
result = {
    'status': 'passed', 'cycles': cycles, 'retired_instructions': instructions, 'ipc': ipc,
    'window_count': len(windows), 'observations': counts,
    'category_percent': {key: counts[key] * 100 / cycles for key in category_names},
    'scope': 'MicroBench mcycle-read retirement windows; observed states, not causal speedup estimates',
    'difftest': False,
}
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
