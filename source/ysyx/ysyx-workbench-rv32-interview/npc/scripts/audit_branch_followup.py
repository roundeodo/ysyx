#!/usr/bin/env python3
"""Validate completed evidence against binaries, source snapshots, windows and clocks."""
import argparse
import json
from pathlib import Path
from explore_frontend import NPC, sha
from followup_branch import defines
from finalize_branch_followup import CANDIDATES
from qualify_branch_runs import check_command
from verify_branch import check_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    completed = json.loads((root / 'evaluation-complete.json').read_text())
    freeze = json.loads((root / 'selection-freeze.json').read_text())
    assert sha(root / 'development-summary.json') == freeze['development_summary_sha256']
    assert sha(root / 'images/manifest.json') == freeze['image_manifest_sha256']
    assert sha(root / 'configurations.json') == freeze['configuration_sha256']
    for relative, expected in freeze['raw_input_hashes'].items():
        assert sha(root / relative) == expected, relative
    config = json.loads((root / 'configurations.json').read_text())
    image_manifest = json.loads((root / 'images/manifest.json').read_text())
    cases = {row['name']: row for row in image_manifest['cases']}
    assert len(cases) == len(image_manifest['cases']) == 22
    assert len({row['kind'] for row in cases.values() if row['held']}) == 6
    for folder, hashes in [('baseline', json.loads((root / 'baseline-manifest.json').read_text())['files']),
                            ('candidate-source', json.loads((root / 'candidate-source/manifest.json').read_text()))]:
        for relative, expected in hashes.items():
            assert sha(root / folder / relative) == expected, (folder, relative)
    binaries = {}
    for name in config:
        build = root / 'builds' / name
        manifest = json.loads((build / 'manifest.json').read_text())
        settings = manifest['settings']
        for setting in defines(config[name]):
            key, value = setting.split('=', 1)
            if key not in settings:
                assert key in ['YSYX_BRANCH_DIRECTION_POLICY', 'YSYX_BRANCH_GLOBAL_HISTORY_BITS']
                assert config[name].get('direction_policy', 0) == 0
            else:
                assert str(settings[key]) == value, (name, key)
        for path, expected in manifest['sources'].items():
            assert sha(Path(path)) == expected, path
        binaries[name] = build / 'obj/Vexploration_core_tb'
    counts = {}
    for path in sorted((root / 'rtl').glob('*/*/results.json')):
        label, name = path.parent.parent.name, path.parent.name
        record = json.loads(path.read_text())
        held = label.startswith('held-')
        rows = record['results']
        expected_names = {case['name'] for case in cases.values() if case['held'] == held}
        assert len(rows) == len(expected_names)
        assert {row['case']['name'] for row in rows} == expected_names
        binary = binaries[name]
        assert record['binary_sha256'] == sha(binary), (label, name)
        assert record['memory_mode'] == 'physical'
        for row in rows:
            case = cases[row['case']['name']]
            assert row['case'] == case
            image = root / 'images' / case['name']
            for filename, expected in case['hashes'].items():
                assert sha(image / filename) == expected
            contents = (image / 'image.bin').read_bytes()
            expected_hex = ''.join(f'{int.from_bytes(contents[i:i+4], "little"):08x}\n'
                                   for i in range(0, len(contents), 4))
            assert (image / 'image.hex').read_text() == expected_hex
            check_command(row['command'], binary, image / 'image.hex', case, record['mhz'],
                          record['latency_ns'], record['beat_ns'], record['random_stalls'], True)
            assert row['result']['checksum'] == case['expected']
            assert row['seconds'] == row['result']['cycles'] / (record['mhz'] * 1e6)
            assert row['ipc'] == row['result']['retired'] / row['result']['cycles']
            c = row['counters']
            assert sum(c[key] for key in ['retire', 'data_wait', 'frontend_wait', 'other']) == row['result']['cycles']
            assert c['btb_missing'] + c['direction'] + c['target'] == c['conditional_errors'] + c['target_errors']
        if label.endswith('own'):
            qualification = json.loads((root / 'ppa' / name / 'qualified.json').read_text())
            assert record['mhz'] == qualification['mhz'] and qualification['all_groups_passed']
        if held:
            assert path.stat().st_mtime > (root / 'selection-freeze.json').stat().st_mtime
        counts.setdefault(label, {})[name] = len(rows)
    common_label = json.loads((root / 'development-summary.json').read_text())['common_label']
    required = {'dev-common': set(config), 'dev-own': set(CANDIDATES + ['B0current']),
                'held-own': set(CANDIDATES), common_label: set(CANDIDATES)}
    if common_label == 'dev-common':
        required[common_label] = set(config)
    for mode in ['fast', 'slow', 'random']:
        required['sensitivity-' + mode] = set(['B0', 'G128', 'R32', freeze['selected']])
    assert set(counts) == set(required), 'Missing or unexpected measurement matrices'
    for label, names in required.items():
        assert set(counts[label]) == names, (label, counts[label])
    for name in ['B0current', 'G64', 'M64', 'G128']:
        path = root / 'verification' / name
        assert json.loads((path / 'manifest.json').read_text())['status'] == 'passed'
        check_sources(path)
    direction = json.loads((root / 'verification/direction-first/results.json').read_text())
    assert len(direction['results']) == 8
    for name, expected in direction['sources'].items():
        assert sha(Path(name)) == expected
    difftest = json.loads((root / 'difftest/results.json').read_text())
    assert sha(Path(difftest['reference'])) == difftest['reference_sha256']
    assert len(difftest['records']) == 30
    for record in difftest['records']:
        assert sha(Path(record['command'][0])) == record['binary_sha256']
    for name in ['B0current', 'G128']:
        report = json.loads((root / 'microbench' / name / 'report.json').read_text())
        assert report['status'] == 'passed' and report['observer_on_off_verified']
        legal = json.loads((root / 'microbench-legal' / name / 'report.json').read_text())
        assert legal['status'] == 'passed' and legal['observer_on_off_verified']
        qualified = json.loads((root / 'ppa' / name / 'qualified.json').read_text())
        assert legal['cpu_mhz'] <= qualified['mhz']
        original = json.loads((root / 'microbench' / name / 'manifest.json').read_text())
        current = json.loads((root / 'microbench-legal' / name / 'manifest.json').read_text())
        assert original['artifacts']['microbench.bin'] == current['artifacts']['microbench.bin']
    assert len(json.loads((root / 'diagnostics/results.json').read_text())['results']) == 30
    assert len(json.loads((root / 'history-observer/G128/results.json').read_text())['results']) == 10
    assert json.loads((root / 'image-reproduction.json').read_text())['status'] == 'passed'
    before = json.loads((root / 'rtl/dev-common/B0/results.json').read_text())['results']
    after = json.loads((root / 'rtl/dev-common/B0current/results.json').read_text())['results']
    for a, b in zip(before, after):
        assert a['case']['name'] == b['case']['name']
        assert a['result'] == b['result'] and a['counters'] == b['counters']
    out = {'status': 'passed', 'matrices': counts, 'software_inputs': 22,
           'direction_cycles': 160000, 'nemu_program_runs': 30,
           'default_disabled_cycle_and_counter_equivalence': True,
           'selected_development': completed['selected'], 'recommendation': completed['recommendation'],
           'old_cache_points': 'functional cycle diagnostics only; not freshly STA-qualified'}
    (root / 'audit.json').write_text(json.dumps(out, indent=2) + '\n')
    print('PASS source, image, binary, command, clock, identity and accounting audit')


if __name__ == '__main__':
    main()
