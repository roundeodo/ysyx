#!/usr/bin/env python3
"""Validate frozen evidence and write the exploration's machine-readable result."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

from run_frontend_matrix import CONFIGS, NPC


def read(path):
    return json.loads(path.read_text())


def geometric(values):
    return math.exp(sum(math.log(x) for x in values) / len(values))


def cases(root, phase, name, mhz, delay=100, beat=10, stalls=0):
    path = root / 'final-results' / f'{phase}-{name}-{mhz}-{delay}-{beat}-{stalls}' / 'results.json'
    data = read(path)
    assert len(data['results']) == 6, path
    return {row['case']['name']: row for row in data['results']}


def comparison(rows, baseline):
    assert rows.keys() == baseline.keys()
    ratios = {}
    for name, row in rows.items():
        reference = baseline[name]
        for key in ['retired', 'all_retired', 'digest', 'checksum']:
            assert row['result'][key] == reference['result'][key], (name, key)
        assert row['case']['hashes'] == reference['case']['hashes'], name
        ratios[name] = row['seconds'] / reference['seconds']
    return {'geomean_time_ratio': geometric(list(ratios.values())),
            'worst_time_ratio': max(ratios.values()), 'case_time_ratios': ratios,
            'total_instruction_beats_ratio': sum(r['counters']['i_beats'] for r in rows.values()) /
                                             sum(r['counters']['i_beats'] for r in baseline.values())}


def index_evidence(root):
    """Index raw evidence without publishing build objects or duplicating traces."""
    entries = []
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if not path.is_file() or path.name == 'raw-index.json':
            continue
        if any(part == 'obj' or part.endswith('_obj') for part in relative.parts):
            continue
        if path.suffix not in {'.json', '.log', '.rpt', '.sdc', '.diff', '.exit', '.trace', '.fetch', '.txt'}:
            continue
        digest = hashlib.sha256()
        with path.open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(block)
        entries.append({'path': str(relative), 'bytes': path.stat().st_size,
                        'sha256': digest.hexdigest()})
    index = {'scope': 'Local raw evidence; diagnostic failures retained; build objects excluded',
             'canonical': ['final-results/', 'final-builds/*/manifest.json', 'ppa-area3/',
                           'microbench/', 'correctness/', 'baseline/', 'selection-freeze.json', 'summary.json'],
             'diagnostic': 'Earlier standalone build/run directories and DELAY0 ppa/ are not final performance tables',
             'entries': entries}
    (root / 'raw-index.json').write_text(json.dumps(index, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    freeze = read(root / 'selection-freeze.json')
    for path, digest in freeze['source_hashes'].items():
        assert hashlib.sha256((NPC / path).read_bytes()).hexdigest() == digest, path
    result = {'schema': 1, 'configuration_order': list(CONFIGS), 'freeze': 'selection-freeze.json',
              'baseline': 'baseline/manifest.json', 'parameters': CONFIGS,
              'scope': 'RV32 CPU software proxies; post-synthesis NanGate45 AREA3; no routed or power claim',
              'window': '(begin marker retirement, end marker retirement]; IPC=retired/cycles; time=cycles/qualified Hz',
              'ppa': {}, 'comparisons': {}, 'sensitivity': {}, 'microbench': {}}
    for name in CONFIGS:
        folder = root / 'ppa-area3' / name
        stat = (folder / 'sta/riscv32_core_reset_boundary-820MHz-buffered/synth_stat.txt').read_text()
        area = float(re.search(r'Chip area for module .*: ([\d.]+)', stat)[1])
        mhz = read(folder / 'qualified.json')['mhz']
        timing = read(folder / 'timing.json')[str(mhz)]
        assert timing['passed'] and not timing['violations']
        result['ppa'][name] = {'area_um2': area, 'qualified_mhz': mhz, 'sta': timing,
                               'source': str(folder.relative_to(root))}
        for path, digest in read(folder / 'source-hashes.json').items():
            assert hashlib.sha256((NPC.parent / path).read_bytes()).hexdigest() == digest, path
    base_area = result['ppa']['B0']['area_um2']
    simple = [n for n in CONFIGS if n != 'C' and result['ppa'][n]['area_um2'] <= 1.05 * base_area]
    for mode in ['same_frequency', 'qualified_frequency']:
        clock = {n: 580 if mode == 'same_frequency' else result['ppa'][n]['qualified_mhz'] for n in CONFIGS}
        development = {n: cases(root, 'dev', n, clock[n]) for n in CONFIGS}
        # Select the comparison using development inputs, never held-out scores.
        best = min(simple, key=lambda n: comparison(development[n], development['B0'])['geomean_time_ratio'])
        result['comparisons'][mode] = {'best_simple_from_dev': best, 'clocks_mhz': clock}
        for phase in ['dev', 'held']:
            rows = development if phase == 'dev' else {n: cases(root, phase, n, clock[n]) for n in CONFIGS}
            result['comparisons'][mode][phase] = {n: {
                'vs_B0': comparison(rows[n], rows['B0']), 'vs_simple': comparison(rows[n], rows[best]),
                'cases': {key: {'cycles': r['result']['cycles'], 'retired': r['result']['retired'],
                                'seconds': r['seconds'], 'ipc': r['ipc'], 'counters': r['counters']}
                          for key, r in rows[n].items()}} for n in CONFIGS}
    for delay, beat, stalls in [(20,10,0), (200,20,0), (100,10,1)]:
        rows = {n: cases(root, 'held', n, 580, delay, beat, stalls) for n in ['B0', 'B3', 'C']}
        result['sensitivity'][f'{delay}ns-{beat}ns-random{stalls}'] = {
            n: {'vs_B0': comparison(rows[n], rows['B0']), 'vs_B3': comparison(rows[n], rows['B3'])}
            for n in rows}
    for name in ['B0', 'B3', 'C']:
        folder = root / 'microbench' / name
        report, manifest = read(folder / 'report.json'), read(folder / 'manifest.json')
        assert report['status'] == 'passed' and report['scale'] == 'test'
        result['microbench'][name] = {'total': report['total'], 'scored': report['scored'],
                                     'bin_sha256': manifest['artifacts']['microbench.bin'],
                                     'elf_sha256': manifest['artifacts']['microbench.elf'],
                                     'report': str((folder / 'report.json').relative_to(root))}
    assert len({x['bin_sha256'] for x in result['microbench'].values()}) == 1
    assert len({x['elf_sha256'] for x in result['microbench'].values()}) == 1
    correctness = root / 'correctness'
    regression = (correctness / 'regression.log').read_text()
    for marker in ['PASS core: 84 cases', 'PASS cache: 75 cases',
                   'PASS FENCE.I controller: 10 cases', 'PASS timer regression']:
        assert marker in regression, marker
    exception_logs = list((correctness / 'exception').glob('mode*.log'))
    assert len(exception_logs) == 40
    assert all('PASS precise exception' in p.read_text() for p in exception_logs)
    difftest = re.sub(r'\x1b\[[0-9;]*m', '', (correctness / 'difftest.log').read_text())
    assert len(re.findall(r'^\[.*\] PASS$', difftest, re.M)) == 35
    assert 'Found and expected 0 SCCs.' in (correctness / 'scc.log').read_text()
    for name in ['lint-candidate-final.log', 'lint-rv64-default-final.log']:
        assert '%Error' not in (correctness / name).read_text(), name
    result['verification'] = {'core_recovery_cases': 84, 'cache_recovery_cases': 75,
        'fence_controller_cases': 10, 'precise_exception_cases': 40, 'difftest_programs': 35,
        'timer_tests': 8, 'system_scc_count': 0,
        'replacement_and_service_probe_manifest': 'correctness/replacement/manifest.json',
        'candidate_npc_soc_lint': 'passed with existing struct-level UNOPTFLAT warnings',
        'rv64_scope': 'default lint only', 'raw_logs': 'correctness/',
        'default_off_check': 'baseline/default-off-equivalence.json'}
    verdict = result['comparisons']['qualified_frequency']['held']['C']['vs_simple']
    result['decision'] = {
        'candidate': 'C', 'area_ratio': result['ppa']['C']['area_um2'] / base_area,
        'passes_time_threshold': verdict['geomean_time_ratio'] <= 0.97,
        'passes_per_case_threshold': verdict['worst_time_ratio'] <= 1.03,
        'passes_area_threshold': result['ppa']['C']['area_um2'] <= 1.05 * base_area,
        'default': 'B0', 'status': 'keep experimentally available; disabled by default',
        'train': 'not rerun; test results do not predict train time'}
    (root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    index_evidence(root)
    print(json.dumps({'ppa': {n: {k:v for k,v in p.items() if k in ['area_um2','qualified_mhz']}
                              for n,p in result['ppa'].items()}, 'decision': result['decision']}, indent=2))


if __name__ == '__main__':
    main()
