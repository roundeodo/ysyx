#!/usr/bin/env python3
"""Run dev cases as frozen synthesis qualifications become available."""
import argparse
import json
from pathlib import Path
import subprocess
import time

from explore_frontend import NPC
from select_icache import CONFIGS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--memory-mode', choices=['cycle', 'physical'], default='physical')
    parser.add_argument('--wait-hours', type=float, default=8)
    parser.add_argument('--configs', nargs='+', choices=CONFIGS, required=True)
    parser.add_argument('--host-opt', type=int, choices=[0, 2], default=0)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    pending = list(args.configs)
    deadline = time.monotonic() + args.wait_hours * 3600
    while pending:
        progress = False
        for name in pending[:]:
            own = root / 'rtl/dev-own' / name / 'results.json'
            if own.exists() and len(json.loads(own.read_text())['results']) == 6:
                assert json.loads(own.read_text()).get('memory_mode', 'cycle') == args.memory_mode
                pending.remove(name)
                progress = True
                continue
            qualified = root / 'ppa' / name / 'qualified.json'
            dev = root / 'rtl/dev-580' / name / 'results.json'
            if not qualified.exists() or not dev.exists() or len(json.loads(dev.read_text())['results']) != 6:
                continue
            command = ['python3', str(NPC / 'scripts/select_icache.py'), '--output', str(root / 'rtl'),
                       '--images', str(root / 'images-v1'), '--configs', name, '--qualified',
                       '--memory-mode', args.memory_mode, '--run-label', 'dev-own', '--no-trace', '--host-opt', str(args.host_opt)]
            if args.resume:
                command.append('--resume')
            subprocess.run(command, check=True)
            pending.remove(name)
            progress = True
        if not progress:
            if time.monotonic() > deadline:
                raise RuntimeError(f'Qualifications/runs remain incomplete: {pending}')
            time.sleep(10)


if __name__ == '__main__':
    main()
