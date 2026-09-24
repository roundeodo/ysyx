#!/usr/bin/env python3
"""Measure the frozen branch matrix at individually legal and common clocks."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import time

from explore_frontend import NPC


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_command(command, binary, image, case, mhz, latency, beat, random_stalls, observer):
    """Bind reported clock/window/model settings to the actual simulator argv."""
    assert Path(command[0]).resolve() == binary.resolve()
    flags = {}
    for argument in command[1:]:
        assert argument.startswith('+') and '=' in argument, argument
        key, value = argument[1:].split('=', 1)
        assert key not in flags, f'Duplicate simulator setting: {key}'
        flags[key] = value
    expected = {'image': str(image), 'begin_pc': f'{case["begin_pc"]:x}',
                'end_pc': f'{case["end_pc"]:x}', 'expected': f'{case["expected"]:x}',
                'cpu_mhz': str(mhz), 'latency_ns': str(latency), 'beat_ns': str(beat),
                'seed': '97531', 'memory_mode': 'physical',
                'random_stalls': str(int(random_stalls)), 'observer': str(int(observer))}
    for key, value in expected.items():
        assert flags.get(key) == value, (key, flags.get(key), value)
    assert set(flags) <= set(expected) | {'trace', 'fetch_trace'}


def run_cases(root, name, label, mhz, *, held=False, latency=100, beat=10,
              random_stalls=False, observer=True):
    """Resume only a complete matching measurement; preserve incomplete outputs."""
    folder = root / 'rtl' / label / name
    path = folder / 'results.json'
    assert read(root / 'builds' / name / 'branch-config.json') == read(root / 'configurations.json')[name]
    if not path.exists():
        if folder.exists():
            raise RuntimeError(f'Inspect preserved partial run before retrying: {folder}')
        command = ['python3', str(NPC / 'scripts/explore_branch.py'), 'run', '--root', str(root),
                   '--config', name, '--run-label', label, '--mhz', str(mhz),
                   '--latency-ns', str(latency), '--beat-ns', str(beat)]
        if held:
            command.append('--held-out')
        if random_stalls:
            command.append('--random-stalls')
        if not observer:
            command.append('--no-observer')
        subprocess.run(command, check=True)
    data = read(path)
    for key, expected in [('mhz', mhz), ('latency_ns', latency), ('beat_ns', beat),
                          ('random_stalls', random_stalls), ('memory_mode', 'physical')]:
        assert data[key] == expected, (path, key, expected)
    assert data['binary_sha256'] == digest(root / 'builds' / name / 'obj/Vexploration_core_tb')
    cases = {row['name']: row for row in read(root / 'images/manifest.json')['cases'] if row['held'] == held}
    assert len(data['results']) == len(cases) == 6
    assert {row['case']['name'] for row in data['results']} == set(cases)
    for row in data['results']:
        assert row['case'] == cases[row['case']['name']]
        assert f'+observer={int(observer)}' in row['command']
        image = root / 'images' / row['case']['name']
        check_command(row['command'], root / 'builds' / name / 'obj/Vexploration_core_tb',
                      image / 'image.hex', row['case'], mhz, latency, beat, random_stalls, observer)
        for filename, expected in row['case']['hashes'].items():
            assert digest(image / filename) == expected, (image, filename)
        content = (image / 'image.bin').read_bytes()
        expected_hex = ''.join(f'{int.from_bytes(content[i:i+4], "little"):08x}\n'
                               for i in range(0, len(content), 4))
        assert (image / 'image.hex').read_text() == expected_hex
    return data


def check_architecture(reference, measured):
    baseline = {row['case']['name']: row['result'] for row in reference['results']}
    names = [row['case']['name'] for row in measured['results']]
    assert len(baseline) == len(reference['results']) == len(names)
    assert set(names) == set(baseline)
    for row in measured['results']:
        for key in ['retired', 'all_retired', 'digest', 'checksum']:
            assert row['result'][key] == baseline[row['case']['name']][key], (row['case']['name'], key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--wait-hours', type=float, default=12)
    parser.add_argument('--jobs', type=int, choices=[1, 2], default=2)
    args = parser.parse_args()
    root = args.root.resolve()
    names = [name for name in read(root / 'configurations.json') if name != 'B0current']
    pending = list(names)
    deadline = time.monotonic() + args.wait_hours * 3600
    baseline = read(root / 'rtl/dev-720/B0/results.json')
    while pending:
        for name in pending[:]:
            qualified = root / 'ppa' / name / 'qualified.json'
            initial = root / 'rtl/dev-720' / name / 'results.json'
            if not qualified.exists() or not initial.exists() or len(read(initial)['results']) != 6:
                continue
            mhz = read(qualified)['mhz']
            check_architecture(baseline, run_cases(root, name, 'dev-own', mhz))
            pending.remove(name)
            print('PASS own clock', name, mhz, flush=True)
        if pending:
            if time.monotonic() > deadline:
                raise RuntimeError(f'Incomplete qualifications: {pending}')
            time.sleep(10)
    common_mhz = min(read(root / 'ppa' / name / 'qualified.json')['mhz'] for name in names)
    def measure_common(name):
        check_architecture(baseline, run_cases(root, name, 'dev-common', common_mhz))

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(measure_common, names))
    (root / 'qualified-runs.json').write_text(json.dumps({
        'status': 'passed', 'common_mhz': common_mhz, 'names': names,
        'qualifications': {name: digest(root / 'ppa' / name / 'qualified.json') for name in names},
        'runs': {label: {name: digest(root / 'rtl' / label / name / 'results.json') for name in names}
                 for label in ['dev-own', 'dev-common']},
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
