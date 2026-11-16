#!/usr/bin/env python3
"""Refine shortlisted mapped netlists on a 5 MHz grid without remapping or replacing evidence."""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NPC/'scripts'))
import sta_report as report
from select_icache_ppa import FLOW


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('names', nargs='+')
    args = parser.parse_args()
    for name in args.names:
        out = NPC/'result/branch-v3/ppa'/name
        coarse = json.loads((out/'qualified.json').read_text())
        assert not (out/'qualified-fine.json').exists()
        mapped = out/'sta/riscv32_core_reset_boundary-820MHz-buffered'
        frequencies = []
        highest = coarse['mhz']
        for mhz in range(highest+5, highest+20, 5):
            target = out/f'sta/riscv32_core_reset_boundary-{mhz}MHz-buffered'
            target.mkdir(exist_ok=False)
            for filename in ['riscv32_core_reset_boundary.netlist.v', 'constraints.sdc']:
                shutil.copy2(mapped/filename, target/filename)
            netlist = target/'riscv32_core_reset_boundary.netlist.v'
            command = [str(FLOW/'bin/iEDA'), '-script', str(FLOW/'scripts/sta.tcl'),
                       str(target/'constraints.sdc'), str(netlist), 'riscv32_core_reset_boundary', 'nangate45']
            (target/'command.json').write_text(json.dumps(command, indent=2)+'\n')
            environment = dict(os.environ, NPC_STA_NETLIST_FILE=str(netlist),
                               CLK_FREQ_MHZ=str(mhz), RUN_POWER_ANALYSIS='0', OMP_NUM_THREADS='2')
            with (target/'sta.log').open('x') as log:
                subprocess.run(command, cwd=FLOW, env=environment, stdout=log,
                               stderr=subprocess.STDOUT, check=True)
            groups = report.timing(target)
            violations = (target/'riscv32_core_reset_boundary.rpt').read_text().count('slack (VIOLATED)')
            passed = not violations and all(value['slack_ns'] >= 0 for value in groups.values())
            frequencies.append({'mhz': mhz, 'passed': passed, 'groups': groups, 'violations': violations})
            print('STA fine', name, mhz, passed, flush=True)
            if not passed:
                break
            highest = mhz
        (out/'timing-fine.json').write_text(json.dumps(frequencies, indent=2)+'\n')
        answer = {**coarse, 'mhz': highest, 'grid_mhz': 5,
                  'search': 'same mapped netlist; 5MHz refinement within measured 20MHz bracket',
                  'source': 'qualified.json plus timing-fine.json'}
        (out/'qualified-fine.json').write_text(json.dumps(answer, indent=2)+'\n')


if __name__ == '__main__':
    main()
