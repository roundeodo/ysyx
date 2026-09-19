#!/usr/bin/env python3
"""Compare frozen measurements with the pre-optimization RV32 baseline."""
import importlib.util
import json
from pathlib import Path
import sys

out = Path(__file__).resolve().parent
root = out.parents[3]
mhz = int(sys.argv[1])
spec = importlib.util.spec_from_file_location('ppa',
    out.parent / 'rv32-readability-ppa-20260919/compare.py')
ppa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ppa)
baseline_ppa = out.parent / 'rv32-precise-exception-20260919/sta'
baseline_perf = out.parent / 'rv32-cycle-opt-20260919/baseline'

def read(path):
    return json.loads(path.read_text())

result = {'baseline_commit': 'c253a1a8fdc168ffaab4e7ea1713617a815d6346',
          'scale': 'test', 'passed_clock_mhz': mhz,
          'ppa_scope': 'core and reset controller, BUF_X4 reset tree with maximum fanout 16, Nangate45 typical, post-synthesis ideal wires',
          'measurements': {}}
for name, bench in [('baseline_700', baseline_perf), ('current_700', out / 'test-700'),
                    (f'current_{mhz}', out / f'test-{mhz}')]:
    report = read(bench / 'report.json')
    manifest = read(bench / 'manifest.json')
    assert report['status'] == 'passed' and report['scale'] == 'test'
    result['measurements'][name] = {key: report[key] for key in
        ['total', 'scored', 'whole_program', 'cpu_mhz', 'device_mhz', 'timer_hz',
         'observer_on_off_verified']}
    result['measurements'][name]['binary_sha256'] = manifest['artifacts']['microbench.bin']
assert len({entry['binary_sha256'] for entry in result['measurements'].values()}) == 1
for name, path in [('baseline', baseline_ppa), ('current', out / 'sta')]:
    cells = ppa.mapped_cells(path / 'riscv32_core_reset_boundary-820MHz-buffered')
    result[name + '_cells'] = cells
    result[name + '_reset_tree'] = read(path / 'riscv32_core_reset_boundary-820MHz-buffered/reset-tree.json')
    frequency = 700 if name == 'baseline' else mhz
    timing = ppa.timing(path / f'riscv32_core_reset_boundary-{frequency}MHz-buffered')
    assert all(group['slack_ns'] >= 0 for group in timing.values())
    result[name + '_passing_timing'] = timing
    result[name + '_sta_820'] = ppa.timing(path / 'riscv32_core_reset_boundary-820MHz-buffered')
base = result['measurements']['baseline_700']
fixed = result['measurements']['current_700']
closed = result['measurements'][f'current_{mhz}']
result['change_percent'] = {
    'area': (result['current_cells']['area_um2'] / result['baseline_cells']['area_um2'] - 1) * 100,
    'total_cycles_same_clock': (fixed['total']['cycles'] / base['total']['cycles'] - 1) * 100,
    'total_ipc_same_clock': (fixed['total']['ipc'] / base['total']['ipc'] - 1) * 100,
    'total_time_passing_clock': (closed['total']['timer_seconds'] / base['total']['timer_seconds'] - 1) * 100,
    'scored_time_passing_clock': (closed['scored']['timer_seconds'] / base['scored']['timer_seconds'] - 1) * 100,
}
(out / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
for key, value in result.items():
    if not key.endswith('_cells'):
        print(key, json.dumps(value, ensure_ascii=False))
