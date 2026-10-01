#!/usr/bin/env python3
"""Collect measured LSU concurrency tradeoffs; reject mismatched final RTL."""
import argparse
import hashlib
import json
from pathlib import Path

NPC = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.input.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    baseline_root = root.parent / 'retire-bypass-20261001'
    paths = {
        'baseline_680': baseline_root / 'perf-final-680/report.json',
        'baseline_700': baseline_root / 'perf-final-700/report.json',
        'single_680': root / 'perf-single-680/report.json',
        'queue_only_680': root / 'perf-queue-680/report.json',
        'before_rollover_680': root / 'perf-adopted-680/report.json',
        'selected_680': root / 'perf-parallel-680/report.json',
        'selected_700': root / 'perf-parallel-700/report.json',
        'miss_priority_660_trial': root / 'perf-selected-660/report.json',
    }
    performance = {name: read(path) for name, path in paths.items()}
    # Older reports keep the image hash in manifest.artifacts, not in report.
    # Check the actual retained image and preserve provenance when normalizing.
    for name, path in paths.items():
        digest = hashlib.sha256((path.parent/'microbench.bin').read_bytes()).hexdigest()
        manifest = read(path.parent/'manifest.json')
        recorded = performance[name].get('image_sha256',
                                        manifest.get('artifacts', {}).get('microbench.bin'))
        assert digest == recorded, 'Software artifact changed: ' + name
        performance[name]['image_sha256'] = digest
        performance[name]['raw_report_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    image_hashes = {value['image_sha256'] for value in performance.values()}
    assert len(image_hashes) == 1, 'Different software images'
    for scope in ('total', 'scored'):
        compared = performance.values() if scope == 'scored' else [p for n,p in performance.items() if n.endswith('_680')]
        assert len({p[scope]['retired_instructions'] for p in compared}) == 1
        assert performance['single_680'][scope]['cycles'] == performance['baseline_680'][scope]['cycles']
        assert performance['queue_only_680'][scope]['cycles'] == performance['baseline_680'][scope]['cycles']
    assert performance['selected_680']['observer_equivalence']['events_identical']
    ppa = {
        'original_rob': read(baseline_root / 'ppa/natural-adder/qualified.json'),
        'single': read(root / 'ppa/single-parallel/qualified.json'),
        'selected': read(root / 'ppa/parallel-valid/qualified.json'),
        'before_route': read(root / 'ppa/adopted-final/qualified.json'),
        'route_only': read(root / 'ppa/route-windows/qualified.json'),
        'uncached_only': read(root / 'ppa/uncached-rollover/qualified.json'),
        'early_response_priority_trial': read(root / 'ppa/response-priority/qualified.json'),
    }
    assert ppa['selected']['mhz'] >= 700, '700 MHz is not qualified'
    source_hashes = read(root / 'ppa/parallel-valid/source-hashes.json')
    formatting_only = []
    for name, digest in source_hashes.items():
        current = NPC.parent/name
        if hashlib.sha256(current.read_bytes()).hexdigest() != digest:
            measured = root/'ppa/parallel-valid/source'/name
            assert [line.lstrip() for line in current.read_text().splitlines()] == [
                line.lstrip() for line in measured.read_text().splitlines()], name
            formatting_only.append({'file':name,'measured_sha256':digest,
                                    'current_sha256':hashlib.sha256(current.read_bytes()).hexdigest(),
                                    'change':'leading indentation only; exact line content unchanged'})
    cases = read(root / 'second-load-parallel/report.json')['cases']
    directed = {}
    for name, variants in cases.items():
        old, new = variants['legacy-loads-first'], variants['rob-loads-first']
        assert old['image_sha256'] == new['image_sha256']
        assert old['retired'] == new['retired']
        directed[name] = {'old_cycles':old['cycles'], 'new_cycles':new['cycles'],
                          'reduction_percent':100*(1-new['cycles']/old['cycles'])}
    old = performance['baseline_680']; new = performance['selected_680']
    legal_old = performance['baseline_700']; legal_new = performance['selected_700']
    area_ratio = ppa['selected']['area_um2']/ppa['original_rob']['area_um2']
    comparison = {'area_increase_percent':100*(area_ratio-1),
                  'area_vs_current_single_percent':100*(ppa['selected']['area_um2']/ppa['single']['area_um2']-1),
                  'area_vs_first_dual_percent':100*(ppa['selected']['area_um2']/ppa['before_route']['area_um2']-1)}
    for scope in ('total','scored'):
        comparison[scope] = {
            'same_frequency_cycle_reduction_percent':100*(1-new[scope]['cycles']/old[scope]['cycles']),
            'qualified_frequency_time_change_percent':100*(legal_new[scope]['cycle_seconds']/legal_old[scope]['cycle_seconds']-1),
            'area_time_change_percent':100*(area_ratio*legal_new[scope]['cycle_seconds']/legal_old[scope]['cycle_seconds']-1),
        }
    verification = {
        'concurrent': read(root/'concurrent-parallel/report.json'),
        'backend_recovery': read(root/'backend-dual/report.json'),
        'route_equations': read(root/'route-equivalence.json'),
        'axi_valid_equations': read(root/'axi-valid-equivalence.json'),
        'core': read(root/'core-parallel/report.json'),
        'quant_kernel': read(root/'kernel-parallel/report.json'),
        'cache_recovery': read(root/'recovery/cache/manifest.json'),
        'fence_i': read(root/'recovery/core/manifest.json'),
    }
    summary = {'scope':'RV32IM; ROB4; I$1024B/4way/32B/p13; D$256B/2way/16B; no latency model change',
               'baseline':read(root/'baseline.json'), 'measured_sources':source_hashes,
               'formatting_only_after_mapping':formatting_only,
               'performance':performance, 'ppa':ppa, 'timing':read(root/'ppa/parallel-valid/timing.json'), 'comparison':comparison,
               'directed':directed, 'verification':verification,
               'default_enabled':False, 'train_run':False,
               'raw_root':str(root), 'image_sha256':next(iter(image_hashes)),
               'timer_note':'1 MHz native timer: 1 us quantization per window; use exact same-window cycles for small differences'}
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    index = []
    for path in sorted(root.rglob('*')):
        if not path.is_file() or any(part in {'source','baseline','build','obj','obj_dir_npc','obj_dir_soc'}
                                     for part in path.relative_to(root).parts):
            continue
        if path.suffix in {'.log','.json','.jsonl','.rpt','.gz'}:
            index.append({'path':str(path.relative_to(root)), 'bytes':path.stat().st_size,
                          'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    (out/'raw-index.json').write_text(json.dumps(index,indent=2)+'\n')
    print(json.dumps(comparison,indent=2))


if __name__ == '__main__':
    main()
