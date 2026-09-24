#!/usr/bin/env python3
"""Build frozen target candidates and measure the development set, no held inputs."""
import argparse
import json
from pathlib import Path
import subprocess
from compact_target_artifacts import prune_objects
from explore_frontend import sha
from finalize_branch_followup import compare


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    a = p.parse_args()
    root = a.root.resolve()
    configurations = json.loads((root / 'configurations.json').read_text())
    for name in ['B0', 'B0off', 'F16', 'U16', 'U32W4', 'H32', 'F32', 'F32W4']:
        for action in ['build', 'run']:
            command = ['python3', 'npc/scripts/explore_target_storage.py', action, '--root', str(root), '--config', name]
            if action == 'run':
                command += ['--mhz', '720', '--label', 'dev-common']
                if name == 'B0':
                    command.append('--trace')
            with (root / (action + '-' + name + '.log')).open('x') as log:
                log.write(json.dumps(command) + '\n')
                log.flush()
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            print('PASS', action, name, flush=True)
        prune_objects(root / 'builds' / name / 'obj')
    reference = json.loads((root / 'rtl/dev-common/B0/results.json').read_text())['results']
    reference = {row['case']['name']: row for row in reference}
    comparisons = {}
    for name in configurations:
        rows = json.loads((root / 'rtl/dev-common' / name / 'results.json').read_text())['results']
        rows = {row['case']['name']: row for row in rows}
        comparisons[name] = compare(rows, reference, 720, 720, 1, 1)
        if name in ['B0off', 'F16']:
            for case, row in rows.items():
                assert row['result'] == reference[case]['result'], (name, case)
                assert row['counters'] == reference[case]['counters'], (name, case)
    (root / 'development-720.json').write_text(json.dumps({
        'scope': 'functional common-clock diagnostic; do not assume candidates pass STA at 720MHz',
        'configurations': comparisons}, indent=2) + '\n')
    (root / 'development-complete.json').write_text(json.dumps({
        'config_sha256': sha(root / 'configurations.json'), 'inputs': 10,
        'integration_and_full_width_control_identical': True}, indent=2) + '\n')
    print('COMPLETE development functional matrix', flush=True)


if __name__ == '__main__':
    main()
