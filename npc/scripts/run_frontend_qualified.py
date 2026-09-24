#!/usr/bin/env python3
"""Rerun fixed physical service times at each configuration's qualified clock."""
import argparse
import json
from pathlib import Path
import subprocess

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    for name in args.configs:
        qualification = json.loads((root / 'ppa-area3' / name / 'qualified.json').read_text())
        assert qualification['all_groups_passed']
        for phase in ['dev', 'held']:
            command = ['python3', str(NPC / 'scripts/run_frontend_matrix.py'),
                       '--root', str(root), '--phase', phase, '--configs', name,
                       '--mhz', str(qualification['mhz'])]
            print(name, phase, qualification['mhz'], flush=True)
            subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
