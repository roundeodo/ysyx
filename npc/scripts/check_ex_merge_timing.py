#!/usr/bin/env python3
"""Probe all four STA groups on one existing reset-buffered core netlist."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from sta_report import timing

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--toolflow', type=Path, required=True)
    parser.add_argument('--mhz', type=int, nargs='+', required=True)
    args = parser.parse_args()
    directory = args.directory.resolve()
    netlist = directory / 'riscv32_core_reset_boundary.netlist.v'
    assert netlist.is_file()
    results = []
    for frequency in args.mhz:
        env = dict(os.environ, CLK_FREQ_MHZ=str(frequency), RUN_POWER_ANALYSIS='0',
                   NPC_STA_NETLIST_FILE=str(netlist))
        command = [str(args.toolflow / 'bin/iEDA'), '-script',
                   str(args.toolflow / 'scripts/sta.tcl'),
                   str(NPC / 'constr/riscv32_core_reset_boundary.sdc'), str(netlist),
                   'riscv32_core_reset_boundary', 'nangate45']
        with (directory / 'probe.log').open('w') as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=180)
        groups = timing(directory)
        record = {'mhz': frequency, 'groups': groups,
                  'passed': all(group['slack_ns'] >= 0 for group in groups.values()),
                  'command': command}
        results.append(record)
        out = directory / 'frequency-checks' / str(frequency)
        out.mkdir(parents=True, exist_ok=True)
        for report in directory.glob('*.rpt'):
            shutil.copy2(report, out / report.name)
        (out / 'timing.json').write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record), flush=True)
    (directory / 'timing.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
