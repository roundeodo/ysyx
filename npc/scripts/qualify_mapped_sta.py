#!/usr/bin/env python3
"""Qualify mapped RTL and, if needed, try bounded equivalent drive-strength repairs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--netlist', type=Path, required=True)
    parser.add_argument('--toolflow', type=Path, required=True)
    parser.add_argument('--sdc', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--frequency', type=float, default=700)
    parser.add_argument('--fanout', type=int, default=0)
    parser.add_argument('--headroom', type=float, default=1.0)
    parser.add_argument('--buffer-cell', default='BUF_X2')
    parser.add_argument('--drive-passes', type=int, default=3,
                        help='Up to two coarse drive passes and one final fine pass')
    args = parser.parse_args()
    assert 0 <= args.drive_passes <= 3
    out = args.output.resolve()
    if out.exists():
        raise SystemExit('Preserve previous results: ' + str(out))
    out.mkdir(parents=True)
    scripts = Path(__file__).resolve().parent
    library = args.toolflow.resolve() / 'pdk/nangate45/lib/Nangate45_typ.lib'
    attempts = []
    netlist = args.netlist.resolve()
    selected = None
    passed = False
    for index in range(args.drive_passes + 1):
        if index:
            sizing = out / f'drive-{index}'
            command = [sys.executable, str(scripts / 'resize_mapped_critical_cells.py'),
                       '--previous', str(selected), '--output', str(sizing),
                       '--liberty', str(library)]
            # After the large arcs improve, shorter arcs can become the bottleneck.
            if index == 3:
                command += ['--minimum-arc-ns', '0.035']
            with (out / f'drive-{index}.log').open('w') as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            attempts.append({'operation': 'drive strength', 'command': command,
                             'exit': result.returncode})
            if result.returncode:
                break
            netlist = sizing / 'resized.v'
        selected = out / f'qualification-{index}'
        command = [sys.executable, str(scripts / 'finish_mapped_sta.py'),
                   '--netlist', str(netlist), '--toolflow', str(args.toolflow.resolve()),
                   '--sdc', str(args.sdc.resolve()), '--output', str(selected),
                   '--frequency', str(args.frequency), '--fanout', str(args.fanout),
                   '--headroom', str(args.headroom), '--buffer-cell', args.buffer_cell]
        print('Qualifying attempt', index, flush=True)
        with (out / f'qualification-{index}.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        attempts.append({'operation': 'full qualification', 'command': command,
                         'exit': result.returncode})
        acceptance = selected / 'acceptance.json'
        if not acceptance.exists():
            break
        passed = result.returncode == 0 and json.loads(acceptance.read_text())['passed']
        if passed:
            break
    # Preserve every trial; expose the actual final reports at the usual output path.
    if selected and selected.exists():
        for source in selected.iterdir():
            if source.is_file():
                shutil.copy2(source, out / source.name)
        if (selected / 'flow-scripts').exists():
            shutil.copytree(selected / 'flow-scripts', out / 'flow-scripts')
    acceptance = out / 'acceptance.json'
    if not passed and acceptance.exists():
        record = json.loads(acceptance.read_text())
        record.update(passed=False, qualification_process_passed=False)
        acceptance.write_text(json.dumps(record, indent=2) + '\n')
    orchestration = out / 'qualification-scripts'
    orchestration.mkdir()
    for name in ['qualify_mapped_sta.py', 'resize_mapped_critical_cells.py']:
        shutil.copy2(scripts / name, orchestration / name)
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    summary = {'passed': passed, 'selected_report_directory': str(selected),
               'original_netlist_sha256': sha(args.netlist), 'attempts': attempts,
               'script_sha256': {p.name: sha(p) for p in orchestration.iterdir()}}
    (out / 'qualification-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('QUALIFIED' if passed else 'FAILED', out)
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
