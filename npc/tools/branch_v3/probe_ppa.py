#!/usr/bin/env python3
"""Check one frequency on a frozen mapped netlist without remapping or changing SDC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

NPC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NPC/'scripts'))
import sta_report
from select_icache_ppa import FLOW


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('--mhz', type=int, default=700)
    args = parser.parse_args()
    assert args.mhz > 0
    root = NPC/'result/branch-v3/ppa'/args.name
    mapped = root/'sta/riscv32_core_reset_boundary-820MHz-buffered'
    target = root/f'sta/riscv32_core_reset_boundary-{args.mhz}MHz-buffered'
    hashes = {}
    for filename in ('riscv32_core_reset_boundary.netlist.v', 'constraints.sdc'):
        hashes[filename] = hashlib.sha256((mapped/filename).read_bytes()).hexdigest()
    if not target.exists():
        target.mkdir()
        for filename in hashes:
            shutil.copy2(mapped/filename, target/filename)
        netlist = target/'riscv32_core_reset_boundary.netlist.v'
        command = [str(FLOW/'bin/iEDA'), '-script', str(FLOW/'scripts/sta.tcl'),
                   str(target/'constraints.sdc'), str(netlist), 'riscv32_core_reset_boundary', 'nangate45']
        environment = {'NPC_STA_NETLIST_FILE': str(netlist), 'CLK_FREQ_MHZ': str(args.mhz),
                       'RUN_POWER_ANALYSIS': '0', 'OMP_NUM_THREADS': '2'}
        (target/'command.json').write_text(json.dumps(command, indent=2)+'\n')
        (target/'environment.json').write_text(json.dumps(environment, indent=2)+'\n')
        with (target/'sta.log').open('x') as log:
            subprocess.run(command, cwd=FLOW, env={**os.environ, **environment},
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    assert 'The timing engine run success.' in (target/'sta.log').read_text()
    for filename, expected in hashes.items():
        assert hashlib.sha256((target/filename).read_bytes()).hexdigest() == expected
    groups = sta_report.timing(target)
    violations = (target/'riscv32_core_reset_boundary.rpt').read_text().count('slack (VIOLATED)')
    result = {'mhz': args.mhz, 'groups': groups, 'violations': violations,
              'passed': not violations and all(group['slack_ns'] >= 0 for group in groups.values()),
              'input_sha256': hashes, 'report': str(target/'riscv32_core_reset_boundary.rpt')}
    (root/f'probe-{args.mhz}.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
