#!/usr/bin/env python3
"""Audit a flattened Yosys JSON netlist before timing the reset boundary.

The raw asynchronous reset may reach only the reset controller's three RN pins.
The qualified reset must be driven by its release register and reach every core
RN, directly or through non-inverting buffers. No timing path is disabled here.
"""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('netlist_json', type=Path)
parser.add_argument('--top', default='riscv32_core_reset_boundary')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
module = json.loads(args.netlist_json.read_text())['modules'][args.top]
cells = module['cells']
raw_bit, = module['ports']['rst_ni']['bits']
raw_sinks = [(name, port) for name, cell in cells.items()
             for port, bits in cell['connections'].items()
             if cell['port_directions'][port] == 'input' and raw_bit in bits]
assert len(raw_sinks) == 3, f'Expected exactly three raw-reset sinks: {raw_sinks}'
release_bit, = module['netnames']['core_rst_n']['bits']
drivers = [(name, port) for name, cell in cells.items()
           for port, bits in cell['connections'].items()
           if cell['port_directions'][port] == 'output' and release_bit in bits]
assert len(drivers) == 1 and drivers[0][1] == 'Q', drivers
release_name = drivers[0][0]
stage_names = [f'u_reset_controller.reset_release_sync_q_{index}__reg_p' for index in range(2)]
assert set(raw_sinks) == {(name, 'RN') for name in [*stage_names, release_name]}, raw_sinks
first, second = (cells[name] for name in stage_names)
release = cells[release_name]
clock_bit, = module['ports']['clk_i']['bits']
assert first['connections']['CK'] == second['connections']['CK'] == [clock_bit]
assert second['connections']['D'] == first['connections']['Q']
assert release['connections']['D'] == second['connections']['Q']
assert any(cell['type'].startswith('INV_X') and cell['connections']['A'] == [clock_bit]
           and cell['connections']['ZN'] == release['connections']['CK']
           for cell in cells.values()), 'Release register is not on the falling clock edge'
reachable = {release_bit}
while True:
    following = {cell['connections']['Z'][0] for cell in cells.values()
                 if cell['type'].startswith('BUF_X') and
                 cell['connections']['A'][0] in reachable}
    if following <= reachable:
        break
    reachable |= following
core_reset_sinks = [(name, cell['connections']['RN'][0]) for name, cell in cells.items()
                    if name not in {*stage_names, release_name} and 'RN' in cell['connections']]
assert core_reset_sinks, 'No core RN pins audited'
assert all(bit in reachable for _, bit in core_reset_sinks), 'Core reset bypassed controller'
summary = {'raw_reset_sinks': raw_sinks, 'release_driver': drivers,
           'core_reset_sink_count': len(core_reset_sinks),
           'qualified_reset_net_count': len(reachable), 'status': 'passed'}
args.output.write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
