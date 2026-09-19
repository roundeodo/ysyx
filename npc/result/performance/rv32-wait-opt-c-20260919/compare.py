#!/usr/bin/env python3
"""Compare this round with 71e44bf using identical hardware and timer scopes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

out = Path(__file__).resolve().parent
root = out.parents[3]
clock = int(sys.argv[1]) if len(sys.argv) > 1 else 600
spec = importlib.util.spec_from_file_location('ppa', out.parent / 'rv32-readability-ppa-20260919/compare.py')
ppa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ppa)

def read(path):
    return json.loads(path.read_text())

result = {'baseline_commit': '71e44bf', 'scale': 'test', 'passing_clock_mhz': clock,
          'ppa_scope': 'core plus reset controller and fanout-16 BUF_X4 tree; Nangate45 typical; ideal wires',
          'candidates': {}}
for name, folder in [('baseline', 'rv32-cycle-opt-final-20260919'),
                     ('a', 'rv32-wait-opt-a-20260919'),
                     ('b', 'rv32-wait-opt-b-20260919'),
                     ('c', 'rv32-wait-opt-c-20260919')]:
    path = out.parent / folder
    report = read(path / 'test-600/report.json')
    manifest = read(path / 'test-600/manifest.json')
    assert report['status'] == 'passed' and report['scale'] == 'test'
    result['candidates'][name] = {
        'cells': ppa.mapped_cells(path / 'sta/riscv32_core_reset_boundary-820MHz-buffered'),
        'timing_600': ppa.timing(path / 'sta/riscv32_core_reset_boundary-600MHz-buffered'),
        'total': report['total'], 'scored': report['scored'],
        'observer_on_off_verified': report['observer_on_off_verified'],
        'binary_sha256': manifest['artifacts']['microbench.bin']}
assert len({entry['binary_sha256'] for entry in result['candidates'].values()}) == 1
closed = read(out / f'test-{clock}/report.json')
timing = ppa.timing(out / f'sta/riscv32_core_reset_boundary-{clock}MHz-buffered')
assert all(group['slack_ns'] >= 0 for group in timing.values()), 'Final frequency does not pass'
assert closed['status'] == 'passed'
result['final'] = {'timing': timing, 'total': closed['total'], 'scored': closed['scored']}
baseline, current = result['candidates']['baseline'], result['candidates']['c']
result['change_percent'] = {
    'area': (current['cells']['area_um2'] / baseline['cells']['area_um2'] - 1) * 100,
    'total_ipc_same_clock': (current['total']['ipc'] / baseline['total']['ipc'] - 1) * 100,
    'total_cycles_same_clock': (current['total']['cycles'] / baseline['total']['cycles'] - 1) * 100,
    'total_time_passing_clock': (closed['total']['timer_seconds'] / baseline['total']['timer_seconds'] - 1) * 100,
    'scored_time_passing_clock': (closed['scored']['timer_seconds'] / baseline['scored']['timer_seconds'] - 1) * 100}
hashes = read(out / 'synthesis-source-hashes.json')
for path, digest in hashes.items():
    assert hashlib.sha256((root / path).read_bytes()).hexdigest() == digest, path
result['synthesis_inputs_match_current'] = len(hashes)
baseline_manifest = read(out.parent / 'rv32-cycle-opt-final-20260919/test-600/manifest.json')
current_manifest = read(out / f'test-{clock}/manifest.json')
assert baseline_manifest['tools'] == current_manifest['tools']
for field in ['scale', 'device_mhz', 'layout', 'reset_cycles', 'interrupt_policy']:
    assert baseline_manifest[field] == current_manifest[field], field
assert all(current_manifest['sources'][path] == digest for path, digest in hashes.items())
non_rtl_changes = [path for path, digest in baseline_manifest['sources'].items()
    if not path.startswith('npc/vsrc/') and path != 'npc/Makefile'
    and current_manifest['sources'].get(path) != digest]
assert not non_rtl_changes, non_rtl_changes
result['unchanged_measurement_inputs'] = True
result['final_simulation_matches_synthesis_sources'] = len(hashes)
(out / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
