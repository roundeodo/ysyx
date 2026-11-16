#!/usr/bin/env python3
"""Qualify mapped exploration netlists on a fixed 20 MHz STA grid.

Only points passing data and clock-gating setup/hold are eligible. This is a
post-synthesis grid search, not a claim about routed silicon Fmax.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

NPC = Path(__file__).resolve().parents[1]
FLOW = NPC / 'result/sta/rv32-interrupt-20260906/toolflow'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location(
        'sta_parser', NPC / 'result/performance/rv32-readability-ppa-20260919/compare.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    for name in args.configs:
        out = args.root.resolve() / name
        mapped = out / 'sta/riscv32_core_reset_boundary-820MHz-buffered'
        results = json.loads((out / 'timing.json').read_text())
        # Check the same bounded frequency grid for every candidate. Failed
        # points remain in the record; never substitute a data-only estimate.
        for mhz in range(800, 479, -20):
            if str(mhz) not in results:
                target = out / f'sta/riscv32_core_reset_boundary-{mhz}MHz-buffered'
                target.mkdir(exist_ok=False)
                for filename in ['riscv32_core_reset_boundary.netlist.v', 'constraints.sdc']:
                    shutil.copy2(mapped / filename, target / filename)
                netlist = target / 'riscv32_core_reset_boundary.netlist.v'
                command = [str(FLOW / 'bin/iEDA'), '-script', str(FLOW / 'scripts/sta.tcl'),
                           str(target / 'constraints.sdc'), str(netlist),
                           'riscv32_core_reset_boundary', 'nangate45']
                env = dict(os.environ, NPC_STA_NETLIST_FILE=str(netlist),
                           CLK_FREQ_MHZ=str(mhz), RUN_POWER_ANALYSIS='0')
                (target / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
                with (target / 'sta.log').open('w') as log:
                    subprocess.run(command, cwd=FLOW, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, check=True)
                groups = helper.timing(target)
                violations = (target / 'riscv32_core_reset_boundary.rpt').read_text().count('slack (VIOLATED)')
                results[str(mhz)] = {'groups': groups, 'violations': violations,
                                    'passed': not violations and all(g['slack_ns'] >= 0 for g in groups.values())}
                (out / 'timing.json').write_text(json.dumps(results, indent=2) + '\n')
            if results[str(mhz)]['passed']:
                (out / 'qualified.json').write_text(json.dumps({
                    'mhz': mhz, 'grid_mhz': 20, 'search_upper_mhz': 800,
                    'all_groups_passed': True, 'source': f'timing.json:{mhz}'}, indent=2) + '\n')
                print(name, 'qualified', mhz, flush=True)
                break
        else:
            raise RuntimeError(f'No legal frequency for {name}')


if __name__ == '__main__':
    main()
