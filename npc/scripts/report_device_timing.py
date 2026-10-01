#!/usr/bin/env python3
"""Archive device timing verification without retaining compiler object trees."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import time

NPC = Path(__file__).resolve().parents[1]
WORKSPACE = NPC.parent


def read_json(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--wait', action='store_true')
    args = parser.parse_args()
    result = args.result.resolve()
    baseline = args.baseline.resolve()
    new = result / 'test-720'
    while args.wait and not (new / 'report.json').exists():
        print('Waiting for full-SoC report; unit matrix has completed.', flush=True)
        time.sleep(30)
    matrix = read_json(result / 'matrix/summary.json')
    report = read_json(new / 'report.json')
    old = read_json(baseline / 'report.json')
    manifest = read_json(new / 'manifest.json')
    old_manifest = read_json(baseline / 'manifest.json')
    assert matrix['passed'] and len(matrix['cases']) == 20
    assert report['status'] == 'passed' and report['observer_on_off_verified']
    assert manifest['artifacts']['microbench.bin'] == old_manifest['artifacts']['microbench.bin']
    changed_cpu = [p for p, digest in old_manifest['sources'].items()
                   if p.startswith('npc/vsrc/riscv32/') and manifest['sources'].get(p) != digest]
    cpu_sources_added = [p for p in manifest['sources']
                         if p.startswith('npc/vsrc/riscv32/') and p not in old_manifest['sources']]
    generated = (WORKSPACE / 'ysyxSoC/build/ysyxSoCFull.v').read_text()
    assert generated.count('.clock           (_apbClockBridge_delayer_device_clock_o)') >= 1
    assert '_axiClockBridge_delayer_device_clock_o' in generated
    archive = NPC / 'docs/verification/data/device-timing-2026-09-28'
    archive.mkdir(parents=True, exist_ok=True)
    summary = {'schema': 1, 'model': 'device-clock-v1', 'device_mhz': 100,
               'unit_groups_passed': len(matrix['cases']), 'cpu_mhz_tested': [100, 200, 250, 580, 720],
               'same_image_sha256': manifest['artifacts']['microbench.bin'],
               'changed_cpu_sources_from_old_run': changed_cpu, 'added_cpu_sources': cpu_sources_added,
               'baseline_report': str(baseline / 'report.json'), 'new_report': str(new / 'report.json'),
               'baseline': {k: old[k] for k in ['total', 'scored']},
               'new': {k: report[k] for k in ['total', 'scored']},
               'train_run': False, 'core_rtl_changed_by_this_task': False,
               'bridge_assumption': 'ideal synchronous event crossing; no asynchronous CDC/PHY cost',
               'raw_logs': str(result), 'observer_on_off_verified': True}
    for window in ['total', 'scored']:
        summary[window + '_cycle_reduction'] = 1 - report[window]['cycles'] / old[window]['cycles']
    (archive / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    shutil.copy2(result / 'matrix/summary.json', archive / 'unit-matrix.json')
    shutil.copy2(result / 'baseline.json', archive / 'baseline.json')
    for name in ['report.json', 'manifest.json']:
        shutil.copy2(new / name, archive / ('new-' + name))
        shutil.copy2(baseline / name, archive / ('old-' + name))
    index = {}
    for p in result.rglob('*.log'):
        index[str(p.relative_to(result))] = {'bytes': p.stat().st_size,
                                           'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
    (archive / 'logs.json').write_text(json.dumps(index, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
