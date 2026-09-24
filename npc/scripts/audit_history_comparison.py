#!/usr/bin/env python3
"""Independently check qualified comparisons against images, binaries and raw logs."""
import json
import math
from pathlib import Path
import re
from functools import lru_cache
from explore_frontend import sha
from finish_history_study import SIMPLE_NAMES


@lru_cache(maxsize=None)
def file_hash(path):
    return sha(Path(path))


def near(actual, expected):
    assert math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-15), (actual, expected)


def audit_comparison(root):
    root = Path(root)
    report = json.loads((root / 'comparison.json').read_text())
    freeze = json.loads((root / 'selection-freeze.json').read_text())
    assert report['freeze'] == freeze
    assert sha(root / 'configurations.json') == freeze['configuration_sha256']
    assert sha(root / 'images/manifest.json') == freeze['images_manifest_sha256']
    configurations = json.loads((root / 'configurations.json').read_text())
    images = json.loads((root / 'images/manifest.json').read_text())['cases']
    image_by_name = {x['name']: x for x in images}
    assert len(image_by_name) == 22
    assert {x['seed'] for x in images if not x['held']} == {331, 733}
    assert {x['seed'] for x in images if x['held']} == {1597, 3253}
    ppa = freeze['ppa']
    frequency = freeze['common_mhz']
    assert frequency == min(x['mhz'] for x in ppa.values())
    phase_paths = set()
    measurements = 0

    def phase(name, label, mhz, held=False, latency=100, stalls=False):
        nonlocal measurements
        folder = root / 'rtl' / label / name
        data = json.loads((folder / 'results.json').read_text())
        assert data['mhz'] == mhz and mhz <= ppa[name]['mhz']
        assert data['latency_ns'] == latency and data['beat_ns'] == 10
        assert data['random_stalls'] == stalls and data['memory_mode'] == 'physical'
        expected = {x['name'] for x in images if x['held'] == held}
        actual = [x['case']['name'] for x in data['results']]
        assert len(actual) == len(set(actual)) and set(actual) == expected
        binary = Path(data['results'][0]['command'][0])
        assert file_hash(str(binary)) == data['binary_sha256']
        build = json.loads((binary.parent.parent / 'manifest.json').read_text())
        assert json.loads((binary.parent.parent / 'config.json').read_text()) == configurations[name]
        for path, value in build['sources'].items():
            assert file_hash(path) == value, path
        for row in data['results']:
            case = row['case']
            assert case == image_by_name[case['name']]
            options = dict(x[1:].split('=', 1) for x in row['command'][1:])
            assert row['command'][0] == str(binary)
            assert Path(options['image']).resolve() == (root / 'images' / case['name'] / 'image.hex').resolve()
            for key, value in [('cpu_mhz', mhz), ('latency_ns', latency), ('beat_ns', 10),
                               ('random_stalls', int(stalls)), ('observer', 1)]:
                assert int(options[key]) == value
            for key in ['begin_pc', 'end_pc']:
                assert int(options[key], 16) == case[key]
            assert int(options['expected'], 16) == case['expected']
            raw = (folder / (case['name'] + '.log')).read_text()
            assert 'PASS proxy' in raw and '%Error' not in raw
            result_line = re.findall(r'^RESULT (.+)$', raw, re.M)
            assert len(result_line) == 1
            parsed = {k: int(v, 16 if k in ['digest', 'checksum'] else 10)
                      for k, v in re.findall(r'(\w+)=([0-9a-f]+)', result_line[0])}
            assert parsed == row['result']
            counts = {}
            for prefix in ['COUNTERS', 'DETAIL']:
                lines = re.findall(r'^' + prefix + r' (.+)$', raw, re.M)
                assert len(lines) == 1
                counts.update({k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', lines[0])})
            assert counts == row['counters']
            assert parsed['checksum'] == case['expected']
            assert sum(counts[k] for k in ['retire', 'data_wait', 'frontend_wait', 'other']) == parsed['cycles']
            assert counts['retire'] == parsed['retired']
            near(row['seconds'], parsed['cycles'] / (mhz * 1e6))
            near(row['ipc'], parsed['retired'] / parsed['cycles'])
        if folder not in phase_paths:
            measurements += len(actual)
            phase_paths.add(folder)
        return {x['case']['name']: x for x in data['results']}

    def score(saved, candidate, baseline, area_ratio):
        assert set(candidate) == set(baseline)
        families = {}
        rows = {}
        for name, row in candidate.items():
            ref = baseline[name]
            for key in ['retired', 'all_retired', 'digest', 'checksum']:
                assert row['result'][key] == ref['result'][key], (name, key)
            ratio = row['seconds'] / ref['seconds']
            families.setdefault(row['case']['kind'], []).append(math.log(ratio))
            rows[name] = (ratio, row['result']['cycles'] / ref['result']['cycles'],
                          row['counters']['i_beats'] / ref['counters']['i_beats'])
        geometric = math.exp(sum(sum(v) / len(v) for v in families.values()) / len(families))
        near(saved['time_ratio_gm'], geometric)
        near(saved['area_ratio'], area_ratio)
        near(saved['area_time_ratio_gm'], geometric * area_ratio)
        near(saved['worst_time_ratio'], max(v[0] for v in rows.values()))
        assert len(saved['cases']) == len(rows)
        assert {x['case'] for x in saved['cases']} == set(rows)
        for item in saved['cases']:
            for key, value in zip(['time_ratio', 'cycle_ratio', 'i_beats_ratio'], rows[item['case']]):
                near(item[key], value)

    common = {}
    own = {}
    for name in ppa:
        assert ppa[name] == json.loads((root / 'ppa' / name / 'qualified.json').read_text())
        label = 'dev-common' if frequency == 720 else f'dev-common-{frequency}'
        common[name] = phase(name, label, frequency)
        mhz = ppa[name]['mhz']
        own[name] = common[name] if mhz == frequency else phase(name, 'dev-common' if mhz == 720 else f'dev-own-{mhz}', mhz)
    for name in common['B0']:
        for field in ['result', 'counters']:
            assert common['B0I'][name][field] == common['B0'][name][field]
    for name in ppa:
        area_ratio = ppa[name]['area_um2'] / ppa['B0']['area_um2']
        score(freeze['development'][name], own[name], own['B0'], area_ratio)
        score(report['common_development'][name], common[name], common['B0'], 1.0)
    dev = freeze['development']
    eligible = [n for n in ppa if n != 'B0I' and dev[n]['worst_time_ratio'] <= 1.03]
    selected = min(eligible, key=lambda n: dev[n]['area_time_ratio_gm'])
    simple = min(SIMPLE_NAMES, key=lambda n: dev[n]['area_time_ratio_gm'])
    tage = min(['T16', 'T32'], key=lambda n: dev[n]['area_time_ratio_gm'])
    assert (selected, simple, tage) == (freeze['selected_development'], freeze['simple_comparator'], freeze['tage_comparator'])
    assert freeze['held_configurations'] == list(dict.fromkeys(['B0', 'B0I', simple, tage, selected]))
    held_common = {}
    held_own = {}
    for name in freeze['held_configurations']:
        held_common[name] = phase(name, f'held-common-{frequency}', frequency, held=True)
        mhz = ppa[name]['mhz']
        held_own[name] = held_common[name] if mhz == frequency else phase(name, f'held-own-{mhz}', mhz, held=True)
    for name in held_common['B0']:
        for field in ['result', 'counters']:
            assert held_common['B0I'][name][field] == held_common['B0'][name][field]
    for name in held_own:
        score(report['held_common_frequency'][name], held_common[name], held_common['B0'], 1.0)
        score(report['held_own_frequency'][name], held_own[name], held_own['B0'], ppa[name]['area_um2'] / ppa['B0']['area_um2'])
    held = report['held_own_frequency'][selected]
    expected_recommendation = selected if held['area_time_ratio_gm'] < 1 and held['worst_time_ratio'] <= 1.03 else 'B0'
    assert report['recommendation'] == expected_recommendation and not report['stable_default_changed']
    assert len(report['sensitivity']) == 3
    for latency, stalls in [(20, False), (200, False), (100, True)]:
        label = f'sensitivity-{latency}-stalls{int(stalls)}-{frequency}'
        base = phase('B0', label, frequency, latency=latency, stalls=stalls)
        assert set(report['sensitivity'][label]) == {simple, tage}
        for name, saved in report['sensitivity'][label].items():
            candidate = phase(name, label, frequency, latency=latency, stalls=stalls)
            score(saved, candidate, base, ppa[name]['area_um2'] / ppa['B0']['area_um2'])
    # The full matrix includes poorly driven historical mappings at 220 MHz.
    # Also audit the already measured practical common point of the finalists;
    # this is diagnostic only and cannot change the frozen selection.
    practical_mhz = min(ppa[n]['mhz'] for n in ['B0', simple, tage, 'G512F'])
    practical_names = list(dict.fromkeys(['B0', simple, tage, 'G512F']))
    practical = {n: phase(n, f'dev-own-{practical_mhz}', practical_mhz)
                 for n in practical_names}
    practical_scores = {}
    for name, rows in practical.items():
        family_logs = {}
        ratios = []
        for case, row in rows.items():
            ref = practical['B0'][case]
            for field in ['retired', 'all_retired', 'digest', 'checksum']:
                assert row['result'][field] == ref['result'][field]
            ratio = row['seconds'] / ref['seconds']
            family_logs.setdefault(row['case']['kind'], []).append(math.log(ratio))
            ratios.append(ratio)
        gm = math.exp(sum(sum(v)/len(v) for v in family_logs.values())/len(family_logs))
        practical_scores[name] = {'time_ratio_gm': gm,
            'area_time_ratio_gm': gm * ppa[name]['area_um2']/ppa['B0']['area_um2'],
            'worst_time_ratio': max(ratios)}
    (root / 'practical-common-frequency.json').write_text(json.dumps({
        'mhz': practical_mhz, 'development': practical_scores,
        'used_for_selection': False, 'status': 'raw logs and bindings audited'}, indent=2)+'\n')
    result = {'status': 'passed', 'phases': len(phase_paths), 'measurements': measurements,
              'checks': 'raw logs, binary/source/image bindings, exact inputs, qualified frequencies, counters, time/IPC, independent weighted aggregation, frozen selection and held acceptance'}
    (root / 'comparison-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
