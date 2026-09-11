#!/usr/bin/env python3
"""Insert a bounded-fanout, non-inverting reset buffer tree in a mapped netlist.

This is a pre-layout electrical repair, not a placement-aware reset-tree flow.
The original mapped netlist and reports are retained. Only loads of the reset
controller's release Q are reconnected; no register or logical function changes.
"""
import argparse
import copy
import json
import math
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--netlist', type=Path, required=True)
parser.add_argument('--liberty', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
parser.add_argument('--top', default='riscv32_core_reset_boundary')
parser.add_argument('--fanout', type=int, default=16)
parser.add_argument('--cell', default='BUF_X4',
                    choices=['BUF_X1', 'BUF_X2', 'BUF_X4', 'BUF_X8', 'BUF_X16'])
args = parser.parse_args()
assert args.fanout >= 2
out = args.output_dir.resolve()
out.mkdir(parents=True, exist_ok=True)
assert args.netlist.resolve() != out / f'{args.top}.netlist.v', 'Preserve the input netlist'

def quote(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'

def yosys(name, commands):
    script = out / f'{name}.ys'
    script.write_text(commands)
    with (out / f'{name}.log').open('w') as log:
        subprocess.run(['yosys', '-Q', '-T', '-s', str(script)],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)

yosys('read', f'read_liberty -lib {quote(args.liberty.resolve())}\n'
             f'read_verilog {quote(args.netlist.resolve())}\n'
             f'hierarchy -top {args.top}\nwrite_json {quote(out / "before.json")}\n')
design = json.loads((out / 'before.json').read_text())
module = design['modules'][args.top]
original = copy.deepcopy(module)
cells = module['cells']
root_bit, = module['netnames']['core_rst_n']['bits']
loads = [(name, port, index) for name, cell in cells.items()
         for port, bits in cell['connections'].items()
         if cell['port_directions'][port] == 'input'
         for index, bit in enumerate(bits) if bit == root_bit]
assert loads, 'No qualified-reset loads found'
next_bit = max(bit for net in module['netnames'].values()
               for bit in net['bits'] if isinstance(bit, int)) + 1
buffer_names = []

def distribute(driver, sinks):
    global next_bit
    if len(sinks) <= args.fanout:
        for name, port, index in sinks:
            cells[name]['connections'][port][index] = driver
        return
    group_count = min(args.fanout, math.ceil(len(sinks) / args.fanout))
    group_size = math.ceil(len(sinks) / group_count)
    for start in range(0, len(sinks), group_size):
        name = f'reset_distribution_buffer_{len(buffer_names)}'
        assert name not in cells
        bit = next_bit
        next_bit += 1
        buffer_names.append(name)
        cells[name] = {'hide_name': 0, 'type': args.cell, 'parameters': {}, 'attributes': {},
                       'port_directions': {'A': 'input', 'Z': 'output'},
                       'connections': {'A': [driver], 'Z': [bit]}}
        module['netnames'][name + '_out'] = {'hide_name': 0, 'bits': [bit], 'attributes': {}}
        distribute(bit, sinks[start:start + group_size])

distribute(root_bit, loads)
# Structural equivalence: every new net is a non-inverting copy of release Q,
# and all pre-existing cells/ports remain identical after collapsing that copy.
canonical = {root_bit: root_bit}
for name in buffer_names:
    cell = cells[name]
    assert cell['type'] == args.cell and cell['connections']['A'][0] in canonical
    canonical[cell['connections']['Z'][0]] = root_bit
collapsed = copy.deepcopy(cells)
for name in buffer_names:
    del collapsed[name]
for cell in collapsed.values():
    for port, bits in cell['connections'].items():
        cell['connections'][port] = [canonical.get(bit, bit) for bit in bits]
assert collapsed == original['cells'], 'Unexpected logic change during buffering'
assert module['ports'] == original['ports']
fanouts = {bit: 0 for bit in canonical}
for cell in cells.values():
    for port, bits in cell['connections'].items():
        if cell['port_directions'][port] == 'input':
            for bit in bits:
                if bit in fanouts:
                    fanouts[bit] += 1
assert max(fanouts.values()) <= args.fanout
(out / 'buffered.json').write_text(json.dumps(design))
netlist = out / f'{args.top}.netlist.v'
yosys('write', f'read_json {quote(out / "buffered.json")}\nhierarchy -top {args.top}\n'
              f'select {args.top}\ntee -o {quote(out / "synth_check.txt")} check -mapped\n'
              f'tee -o {quote(out / "synth_stat.txt")} stat -liberty {quote(args.liberty.resolve())}\n'
              f'write_verilog -noattr -noexpr -nohex -nodec {quote(netlist)}\n')
summary = {'source_netlist': str(args.netlist.resolve()), 'top': args.top,
           'buffer_cell': args.cell, 'buffer_count': len(buffer_names),
           'reset_load_count': len(loads), 'maximum_inserted_tree_fanout': max(fanouts.values()),
           'structural_equivalence': 'passed',
           'scope': 'Mapped-cell buffering only; placement and routed parasitics not included'}
(out / 'reset-tree.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
