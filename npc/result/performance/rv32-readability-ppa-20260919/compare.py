#!/usr/bin/env python3
"""Compare the archived baseline with this run; never infer train from test."""
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE.parent / 'frontend-rewrite-20260915'


def mapped_cells(directory):
    stat = (directory / 'synth_stat.txt').read_text()
    cells = {name: int(count) for count, name in
             re.findall(r'^\s+(\d+)\s+[\d.eE+]+\s+(\w+_X\d+)\s*$', stat, re.M)}
    return {
        'area_um2': float(re.search(r"Chip area for module .*: ([\d.]+)", stat)[1]),
        'dff': sum(count for name, count in cells.items() if name.startswith('DFF')),
        'data_latches': sum(count for name, count in cells.items() if name.startswith('DL')),
        'clock_gates': sum(count for name, count in cells.items() if name.startswith('CLKGATE')),
        'cells': cells,
    }


def timing(directory):
    report = (directory / 'riscv32_core_reset_boundary.rpt').read_text()
    groups = {}
    for line in report.splitlines():
        row = [field.strip() for field in line.split('|')[1:-1]]
        if len(row) != 8 or row[2] not in ('max', 'min'):
            continue
        key = ('gating_' if 'gating' in row[1] else 'data_') + row[2]
        groups.setdefault(key, []).append({'endpoint': row[0], 'slack_ns': float(row[6]),
                                          'fmax_mhz': None if row[7] == 'NA' else float(row[7])})
    assert len(groups) == 4, groups
    return {key: min(rows, key=lambda row: row['slack_ns']) for key, rows in groups.items()}


def main():
    result = {'baseline': str(BASE), 'current': str(HERE)}
    for name, root in [('baseline', BASE / 'sta'), ('current', HERE / 'sta-current')]:
        result[name + '_cells'] = mapped_cells(root / 'riscv32_core_reset_boundary-820MHz-buffered')
        for frequency in (820, 700):
            result[f'{name}_sta_{frequency}'] = timing(root / f'riscv32_core_reset_boundary-{frequency}MHz-buffered')
    reports, manifests = {}, {}
    for name, root in [('baseline', BASE), ('current', HERE)]:
        bench = root / 'microbench-test-700'
        reports[name] = json.loads((bench / 'report.json').read_text())
        manifests[name] = json.loads((bench / 'manifest.json').read_text())
        assert reports[name]['status'] == 'passed' and reports[name]['scale'] == 'test'
    fields = ['total', 'scored', 'subtests', 'whole_program', 'timer_contexts']
    result['benchmark'] = {
        'equal_windows': {field: reports['baseline'][field] == reports['current'][field] for field in fields},
        'identical_binary': manifests['baseline']['artifacts']['microbench.bin'] == manifests['current']['artifacts']['microbench.bin'],
        'identical_elf': manifests['baseline']['artifacts']['microbench.elf'] == manifests['current']['artifacts']['microbench.elf'],
        'identical_tools': manifests['baseline']['tools'] == manifests['current']['tools'],
        'total': reports['current']['total'],
        'scored': reports['current']['scored'],
    }
    sources = manifests['baseline']['sources']
    result['non_rtl_input_changes'] = [path for path, digest in sources.items()
        if not path.startswith('npc/vsrc/') and path != 'npc/Makefile'
        and manifests['current']['sources'].get(path) != digest]
    (HERE / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if not key.endswith('_cells')}, indent=2))


if __name__ == '__main__':
    main()
