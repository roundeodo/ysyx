#!/usr/bin/env python3
"""Reject incomplete timing, reset, capacitance, slew or fanout qualification."""
import argparse
import json
from pathlib import Path
import re


def electrical_report(path):
    rows = []
    for line in path.read_text().splitlines():
        fields = [part.strip() for part in line.split('|')[1:-1]]
        if len(fields) != 6 or fields[3] in {'', 'NA'}:
            continue
        values = re.findall(r'(-?\d+\.\d+)[rf]?', fields[3])
        if not values:
            continue
        rows.append({'pin': fields[0], 'slack': fields[3],
                     'passed': all(not value.startswith('-') for value in values)})
    if not rows:
        raise ValueError('Missing electrical checks: ' + str(path))
    return {'reported_rows': rows, 'passed': all(row['passed'] for row in rows)}


def timing_report(path):
    text = path.read_text()
    groups = {}
    tns_by_clock = {}
    for line in text.splitlines():
        row = [part.strip() for part in line.split('|')[1:-1]]
        if len(row) == 8 and row[2] in {'max', 'min'}:
            key = ('gating_' if 'gating' in row[1] else 'data_') + row[2]
            record = {'endpoint': row[0], 'slack_ns': float(row[6])}
            if key not in groups or record['slack_ns'] < groups[key]['slack_ns']:
                groups[key] = record
        elif len(row) == 3 and row[1] in {'max', 'min'}:
            tns_by_clock.setdefault(row[0], {})[row[1]] = float(row[2])
    if set(groups) != {'data_max', 'data_min', 'gating_max', 'gating_min'}:
        raise ValueError('Missing timing groups: ' + str(path))
    if not tns_by_clock or any(set(values) != {'max', 'min'}
                               for values in tns_by_clock.values()):
        raise ValueError('Missing timing TNS')
    tns = {mode: sum(values[mode] for values in tns_by_clock.values())
           for mode in ('max', 'min')}
    violations = text.count('slack (VIOLATED)')
    return {'groups': groups, 'tns_ns': tns, 'tns_by_clock_ns': tns_by_clock,
            'reported_violations': violations,
            'passed': not violations and all(r['slack_ns'] >= 0 for r in groups.values())
                      and all(value >= 0 for value in tns.values())}


def clock_coverage_report(path):
    text = path.read_text()
    endpoints = sorted(set(re.findall(r'end vertex (.+) has no clock data\.', text)))
    count = text.count('has no clock data')
    return {'missing_clock_diagnostics': count, 'missing_clock_endpoints': endpoints,
            'passed': count == 0}


def qualify(directory, top):
    if 'The timing engine run success.' not in (directory / 'sta.log').read_text():
        raise ValueError('STA did not finish')
    clocks = clock_coverage_report(directory / 'sta.log')
    timing = timing_report(directory / (top + '.rpt'))
    capacitance = electrical_report(directory / (top + '.cap'))
    transition = electrical_report(directory / (top + '.trans'))
    reset = json.loads((directory / 'reset-connectivity.json').read_text())
    repair = json.loads((directory / 'electrical-repair.json').read_text())
    fanout_limit = repair.get('project_fanout_limit')
    fanout_passed = fanout_limit is None or repair['maximum_cell_output_fanout'] <= fanout_limit
    structural = (reset['status'] == 'passed' and repair['structural_equivalence'] == 'passed'
                  and repair['static_load_audit'] == 'passed' and fanout_passed)
    return {'timing': timing, 'capacitance': capacitance, 'transition': transition,
            'clock_coverage': clocks,
            'reset_and_connection_audits_passed': structural,
            'project_fanout_limit': fanout_limit,
            'maximum_cell_output_fanout': repair['maximum_cell_output_fanout'],
            'passed': structural and clocks['passed'] and timing['passed']
                      and capacitance['passed'] and transition['passed'],
            'scope': 'Single-corner mapped-cell checks with ideal clocks; no CTS/routed signoff'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--top', default='riscv_core_reset_boundary')
    args = parser.parse_args()
    result = qualify(args.directory, args.top)
    (args.directory / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()
