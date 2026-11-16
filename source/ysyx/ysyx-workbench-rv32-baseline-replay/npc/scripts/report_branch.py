#!/usr/bin/env python3
"""Archive compact branch results and an index of the complete original evidence."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil

from explore_frontend import NPC, sha
from qualify_branch_runs import check_architecture, read, run_cases
from select_branch import summarize


def screening_records(root):
    baseline = read(root / 'rtl/dev-720/B0/results.json')
    summary, decomposition = {}, {}
    for name in read(root / 'configurations.json'):
        path = root / 'rtl/dev-720' / name / 'results.json'
        measured = read(path)
        check_architecture(baseline, measured)
        ratios = [row['seconds'] / base['seconds'] for row, base in zip(measured['results'], baseline['results'])]
        summary[name] = {'time_ratio_gm': math.prod(ratios) ** (1 / len(ratios)),
                         'worst_time_ratio': max(ratios),
                         'errors': sum(sum(row['counters'][key] for key in ['btb_missing', 'direction', 'target'])
                                       for row in measured['results']),
                         **{key: sum(row['counters'][key] for row in measured['results'])
                            for key in ['i_beats', 'd_beats', 'queries']}, 'source_sha256': sha(path)}
        decomposition[name] = []
        for row, base in zip(measured['results'], baseline['results']):
            classes = ['retire', 'data_wait', 'frontend_wait', 'other']
            assert sum(row['counters'][key] for key in classes) == row['result']['cycles']
            keys = classes + ['misses', 'queries', 'i_beats', 'd_beats', 'btb_missing', 'direction', 'target']
            decomposition[name].append({'case': row['case']['name'],
                'cycle_delta': row['result']['cycles'] - base['result']['cycles'],
                'deltas': {key: row['counters'][key] - base['counters'][key] for key in keys}})
    records = {
        'development-screen.json': {'mhz': 720, 'scope': 'initial cycle screening, some candidates do not qualify at this clock; final comparison uses qualified clocks', 'rows': summary},
        'cycle-decomposition.json': {'scope': '720 MHz functional cycle screening; mutually exclusive priority classifications, not causal stall penalties', 'cases': decomposition}}
    for name, data in records.items():
        path = root / name
        if path.exists():
            assert read(path) == data, f'Screening records changed: {name}'
        else:
            path.write_text(json.dumps(data, indent=2) + '\n')


def audit_measurements(root):
    """Reject stale images, mismatched snapshots and unqualified clock claims."""
    qualified = read(root / 'qualified-runs.json')
    frozen = read(root / 'selection-freeze.json')
    for relative, expected in frozen['inputs'].items():
        assert sha(root / relative) == expected, relative
    for name, expected in qualified['qualifications'].items():
        assert sha(root / 'ppa' / name / 'qualified.json') == expected, name
    for label, names in qualified['runs'].items():
        for name, expected in names.items():
            assert sha(root / 'rtl' / label / name / 'results.json') == expected, (label, name)
    configurations = read(root / 'configurations.json')
    for name in configurations:
        folder = root / 'ppa' / name
        point = read(folder / 'qualified.json')
        timing = read(folder / 'timing.json')
        legal = timing[str(point['mhz'])]
        assert set(legal['groups']) == {'data_max', 'data_min', 'gating_max', 'gating_min'}
        assert legal['passed'] and legal['violations'] == 0
        assert all(group['slack_ns'] >= 0 for group in legal['groups'].values())
        if point['mhz'] < point['search_upper_mhz']:
            assert not timing[str(point['mhz'] + point['grid_mhz'])]['passed']
        assert point['area_um2'] == read(folder / 'cells.json')['area_um2']
        snapshot = root / ('baseline' if name == 'B0' else 'candidate-source')
        for relative, expected in read(folder / 'source-hashes.json').items():
            assert sha(folder / 'source' / relative) == expected, (name, relative)
            assert sha(snapshot / relative) == expected, (name, 'frozen source', relative)
    runs = []
    for path in sorted((root / 'rtl').glob('*/*/results.json')):
        label, name = path.parent.parent.name, path.parent.name
        data = read(path)
        held = data['results'][0]['case']['held']
        observer = '+observer=1' in data['results'][0]['command']
        measured = run_cases(root, name, label, data['mhz'], held=held,
                             latency=data['latency_ns'], beat=data['beat_ns'],
                             random_stalls=data['random_stalls'], observer=observer)
        reference = read(root / 'rtl' / ('held-own' if held else 'dev-720') / 'B0/results.json')
        check_architecture(reference, measured)
        for row in measured['results']:
            cycles, retired = row['result']['cycles'], row['result']['retired']
            assert math.isclose(row['seconds'], cycles / (data['mhz'] * 1e6), rel_tol=1e-12)
            assert math.isclose(row['ipc'], retired / cycles, rel_tol=1e-12)
            if observer:
                assert row['counters']['retire'] == retired
                assert sum(row['counters'][key] for key in ['retire', 'data_wait', 'frontend_wait', 'other']) == cycles
        runs.append({'path': str(path.relative_to(root)), 'sha256': sha(path), 'cases': len(measured['results'])})
    result = {'status': 'passed', 'ppa_configurations': len(configurations),
              'rtl_runs': len(runs), 'rtl_cases': sum(run['cases'] for run in runs),
              'checks': ['frozen selection inputs', 'image and simulator hashes', 'architectural output and retirement',
                         'IPC and time window', 'cycle accounting', 'all four timing groups and upper neighbour',
                         'PPA source snapshots'], 'runs': runs}
    (root / 'measurement-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.root.resolve(), args.output.resolve()
    validation = read(root / 'final-validation.json')
    assert validation['status'] == 'passed'
    screening_records(root)
    audit = audit_measurements(root)
    frozen = read(root / 'selection-freeze.json')
    qualifications = read(root / 'qualified-runs.json')
    names = qualifications['names']
    groups = {'dev-own': names, 'dev-common': names}
    groups.update({label: frozen['held_names'] for label in ['held-own', 'held-common']})
    rows = {label: [summarize(root, name, label) for name in configs] for label, configs in groups.items()}
    followup = read(root / 'validation-complete.json')['names']
    for label in ['held-fast', 'held-slow', 'held-random']:
        rows[label] = [summarize(root, name, label) for name in followup]
    current = read(root / 'ppa/B0current/qualified.json')
    baseline = read(root / 'ppa/B0/qualified.json')
    report = {'measurement_audit': audit, 'decision': read(root / 'decision.json'), 'common_mhz': qualifications['common_mhz'],
              'configurations': read(root / 'configurations.json'), 'measurements': rows,
              'traffic_semantics': {'i_beats': 'accepted instruction R beats',
                                    'd_transfer_cycles': 'cycles with an accepted data R or W beat; simultaneous R/W count once',
                                    'raw_d_beats': 'legacy raw counter name for d_transfer_cycles; do not treat its sum with i_beats as total bus beats'},
              'microbench_test': validation['microbench_test'],
              'default_off': {'behavioral_equivalence': read(root / 'verification/default-equivalence.json'),
                              'original_ppa': baseline, 'current_ppa': current,
                              'area_ratio': current['area_um2'] / baseline['area_um2']},
              'limitations': ['integer RV32I software proxies, not full model inference',
                              'fresh held inputs use the same generators and libraries',
                              'proxy checks use retired PC/GPR digest, retirement count and independent output; no full architectural DiffTest in this batch',
                              'synthesis/STA estimate, no place-and-route or measured power',
                              '720 MHz screening is distinct from the common legal frequency',
                              'MicroBench test is a regression; train was not rerun']}
    out.mkdir(parents=True, exist_ok=True)
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    flat = []
    for label, configs in rows.items():
        for config in configs:
            for case in config['cases']:
                flat.append(dict(window=label, configuration=config['name'], mhz=config['mhz'],
                                 area_um2=config['area_um2'], **case))
    with (out / 'cases.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(flat[0]))
        writer.writeheader()
        writer.writerows(flat)
    compact = ['configurations.json', 'selection-freeze.json', 'decision.json', 'qualified-runs.json',
               'final-validation.json', 'validation-complete.json', 'measurement-audit.json', 'baseline/manifest.json',
               'baseline/provenance-supplement.json', 'baseline/toolchain-files.json',
               'candidate-source/manifest.json', 'direction-model-v1/results.json',
               'direction-model-v1/functions.json',
               'direction-alignment/results.json',
               'model-v3/results.json', 'verification/default-equivalence.json',
               'verification/predictor-final/predictor/manifest.json']
    if (root / 'verification/predictor-first/finding.json').exists():
        compact.append('verification/predictor-first/finding.json')
    for relative in ['development-screen.json', 'cycle-decomposition.json', 'direction-model-v1/source-hashes.json',
                     'direction-model-v1/profile-source-hashes.json', 'direction-alignment/source-hashes.json',
                     'references/extended/index.json']:
        if (root / relative).exists():
            compact.append(relative)
    for name in [*names, 'B0current']:
        compact += [f'ppa/{name}/{file}' for file in
                    ['qualified.json', 'timing.json', 'cells.json', 'command.json', 'source-hashes.json']]
    for relative in compact:
        source = root / relative
        target = out / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    logs = []
    for path in sorted(root.rglob('*')):
        if out in path.parents:
            continue
        if not path.is_file() or path.suffix not in ('.json', '.jsonl', '.log', '.rpt'):
            continue
        relative = path.relative_to(root)
        # The reporting command can still be writing its own stdout log.
        if relative in (Path('report.log'), Path('report-driver.log')):
            continue
        if any(part in ('obj', 'source', 'candidate-source', 'baseline') for part in relative.parts):
            continue
        logs.append({'path': str(relative), 'bytes': path.stat().st_size, 'sha256': sha(path)})
    (out / 'raw-log-index.json').write_text(json.dumps({'root': str(root), 'files': logs}, indent=2) + '\n')
    scripts = ['explore_branch.py', 'model_branch.py', 'test_branch_model.py', 'run_branch_matrix.py',
               'run_branch_ppa.py', 'qualify_branch_runs.py', 'select_branch.py', 'verify_branch.py',
               'finish_branch_regressions.py', 'report_branch.py', 'run_microbench_perf.py',
               'select_icache_ppa.py', 'sta_report.py', 'explore_frontend.py', 'build_selection_workloads.py',
               'reproduce_branch.py', 'model_direction.py', 'test_direction_model.py', 'test_branch_measurement.py',
               'profile_branch_direction.py']
    source_files = [NPC / 'scripts' / name for name in scripts]
    source_files += [NPC / 'Makefile', NPC / 'vsrc/riscv32/filelist/filelist_sta.f',
                     NPC / 'constr/riscv32_core_reset_boundary.sdc',
                     NPC / 'tests/rtl/riscv32_predictor_contract_tb.sv']
    (out / 'delivery-sources.json').write_text(json.dumps(
        {str(path.relative_to(NPC.parent)): sha(path) for path in source_files}, indent=2) + '\n')
    print('ARCHIVED', out, 'raw records', len(logs), flush=True)


if __name__ == '__main__':
    main()
