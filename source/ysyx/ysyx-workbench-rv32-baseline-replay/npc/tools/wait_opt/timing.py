#!/usr/bin/env python3
"""Probe an AREA 3 netlist at legal frequencies and retain compact reports."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

NPC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NPC / 'scripts'))
import sta_report


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('work', type=Path, nargs='?',
                        default=NPC / 'result/wait-opt-synthesis/current')
    args = parser.parse_args()
    assert args.name.replace('-', '').isalnum()
    work = args.work.resolve()
    assert work.is_relative_to(NPC / 'result')
    assert (work / '.npc-generated-workspace').is_file()
    output = NPC / 'docs/verification/data/wait-opt-20261002' / args.name / 'ppa'
    output.mkdir(parents=True, exist_ok=False)
    flow = NPC / 'result/sta/rv32-interrupt-20260906/toolflow'
    top = 'riscv32_core_reset_boundary'
    mapped = work / 'sta' / f'{top}-820MHz-buffered'
    cells = sta_report.mapped_cells(mapped)
    print('AREA', args.name, cells['area_um2'], flush=True)
    save_json(output / 'cells.json', cells)
    shutil.copyfile(work / 'configuration.json', output / 'configuration.json')
    netlist = mapped / f'{top}.netlist.v'
    (output / 'netlist-sha256.txt').write_text(
        hashlib.sha256(netlist.read_bytes()).hexdigest() + '\n')
    probe = work / 'probe'
    probe.mkdir(exist_ok=True)
    for filename in [netlist.name, 'constraints.sdc']:
        shutil.copyfile(mapped / filename, probe / filename)
    records = []
    mhz = 700
    while True:
        command = [str(flow / 'bin/iEDA'), '-script', str(flow / 'scripts/sta.tcl'),
                   str(probe / 'constraints.sdc'), str(probe / netlist.name),
                   top, 'nangate45']
        env = dict(os.environ, NPC_STA_NETLIST_FILE=str(probe / netlist.name),
                   CLK_FREQ_MHZ=str(mhz), RUN_POWER_ANALYSIS='0', OMP_NUM_THREADS='2')
        with (probe / 'sta.log').open('w') as log:
            subprocess.run(command, cwd=flow, env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True)
        groups = sta_report.timing(probe)
        violations = (probe / f'{top}.rpt').read_text().count('slack (VIOLATED)')
        passed = violations == 0 and all(g['slack_ns'] >= 0 for g in groups.values())
        destination = output / str(mhz)
        destination.mkdir()
        for report in probe.glob('*.rpt'):
            (destination / (report.name + '.gz')).write_bytes(
                gzip.compress(report.read_bytes(), mtime=0))
        records.append(dict(mhz=mhz, passed=passed, violations=violations,
                            groups=groups, command=command))
        save_json(output / 'timing.json', records)
        print('STA', args.name, mhz, passed, groups, flush=True)
        if passed:
            if any(not r['passed'] for r in records) or mhz >= 740:
                break
            mhz += 5
        else:
            if any(r['passed'] for r in records):
                break
            # A conservative legal point for a rejected prototype, not its maximum.
            mhz = min(mhz - 10, int(groups['data_max']['fmax_mhz'] * 0.95) // 10 * 10)
            assert mhz >= 400, 'No legal frequency above 400 MHz'
    save_json(output / 'qualified.json', {
        'area_um2': cells['area_um2'],
        'passed_mhz': max(r['mhz'] for r in records if r['passed']),
        'grid_note': '5 MHz upward from 700; conservative lower point after failure, '
                     'not necessarily the maximum; require all four STA groups',
    })
    # Archive reports and source binding before deleting scratch products.
    shutil.rmtree(work / 'sta')
    shutil.rmtree(probe)
    for scratch in work.glob('probe_sta_*'):
        if scratch.is_dir():
            shutil.rmtree(scratch)


if __name__ == '__main__':
    main()
