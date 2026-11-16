#!/usr/bin/env python3
"""Summarize completed hardware experiments; never infer an unfinished train result."""
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
previous_path = root / "summary.json"
previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
summary = {}
for variant in ['baseline', 'merge-decode', 'merge-decode-read', 'lsu-completion-issue']:
    directory = root / variant
    result = {}
    for scale in ['test', 'train']:
        path = directory / f'{scale}.json'
        result[scale] = json.loads(path.read_text()) if path.exists() else {'status': 'pending'}
    sta = directory / 'sta/riscv32_core_reset_boundary-820MHz-buffered'
    report = sta / 'riscv32_core_reset_boundary.rpt'
    if report.exists() and 'timing engine run success' in (sta / 'sta.log').read_text():
        fingerprint = [file.stat().st_mtime_ns for file in [report, sta / 'synth_stat.txt', sta / 'buffered.json']]
        cached = previous.get(variant, {}).get('ppa', {})
        if cached.get('artifact_fingerprint') == fingerprint:
            result['ppa'] = cached
        else:
            area_match = re.search(r'Chip area.*:\s*([\d.]+)', (sta / 'synth_stat.txt').read_text())
            rows = []
            for line in report.read_text().splitlines():
                fields = [field.strip() for field in line.strip().strip('|').split('|')]
                if len(fields) == 8 and fields[2] in ['min', 'max']:
                    rows.append({'endpoint': fields[0], 'group': fields[1], 'type': fields[2],
                                 'slack_ns': float(fields[6]),
                                 'estimated_fmax_mhz': float(fields[7]) if fields[7] != 'NA' else None})
            cells = json.loads((sta / 'buffered.json').read_text())['modules']['riscv32_core_reset_boundary']['cells']
            result['ppa'] = {
                'area_um2': float(area_match[1]),
                'flipflops': sum(c['type'].startswith(('DFF', 'SDFF')) for c in cells.values()),
                'clock_mhz': 820, 'worst_slack_ns': min(row['slack_ns'] for row in rows),
                'setup_slack_ns': min(row['slack_ns'] for row in rows if row['group'] == 'core_clock' and row['type'] == 'max'),
                'hold_slack_ns': min(row['slack_ns'] for row in rows if row['group'] == 'core_clock' and row['type'] == 'min'),
                'timing_passed': all(row['slack_ns'] >= 0 for row in rows),
                'estimated_fmax_mhz': min(row['estimated_fmax_mhz'] for row in rows if row['estimated_fmax_mhz'] is not None),
                'worst_setup_endpoint': next(row['endpoint'] for row in rows if row['group'] == 'core_clock' and row['type'] == 'max'),
                'scope': 'NanGate45 typ, Yosys DELAY 0 + iSTA, same reset wrapper and buffer policy; no routed parasitics',
            }
            result['ppa']['artifact_fingerprint'] = fingerprint
    summary[variant] = result
(root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
for name, result in summary.items():
    print(name, json.dumps({key: ({k: v for k, v in val.items() if k in ['status', 'ipc', 'cycles', 'area_um2', 'setup_slack_ns', 'timing_passed', 'estimated_fmax_mhz']} if isinstance(val, dict) else val) for key, val in result.items()}))
