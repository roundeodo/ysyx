#!/usr/bin/env python3
"""Run a bounded branch RTL matrix from one immutable source snapshot."""
import argparse
import json
from pathlib import Path
import subprocess

from explore_frontend import NPC
from qualify_branch_runs import run_cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    baseline = json.loads((root / 'rtl/dev-720/B0/results.json').read_text())
    expected = {row['case']['name']: row['result'] for row in baseline['results']}
    for name in args.configs:
        common = ['python3', str(NPC / 'scripts/explore_branch.py'), '--root', str(root), '--config', name]
        build = root / 'builds' / name
        if not (build / 'branch-config.json').exists():
            if build.exists():
                raise RuntimeError(f'Incomplete build retained: {build}')
            subprocess.run([*common, 'build', '--source-root', str(root / 'candidate-source')], check=True)
        rows = run_cases(root, name, 'dev-720', 720)['results']
        assert len(rows) == len(expected)
        for row in rows:
            for key in ['retired', 'all_retired', 'digest', 'checksum']:
                assert row['result'][key] == expected[row['case']['name']][key], (name, row['case']['name'], key)
        print('PASS RTL', name, flush=True)


if __name__ == '__main__':
    main()
