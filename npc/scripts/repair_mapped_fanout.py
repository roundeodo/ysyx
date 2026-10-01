#!/usr/bin/env python3
"""Repair mapped loads with non-inverting buffers and audit every original pin.

This is a pre-layout step. It does not implement placement or clock-tree
synthesis. Input ports retain their specified external drive/transition model.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess


def groups(text, kind):
    """Yield Liberty groups, skipping braces inside strings and comments."""
    opening = re.compile(r'\b' + kind + r'\s*\(\s*([^()]+?)\s*\)\s*\{')
    tokens = re.compile(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[{}]', re.S)
    position = 0
    while match := opening.search(text, position):
        depth = 1
        for token in tokens.finditer(text, match.end()):
            if token.group() == '{':
                depth += 1
            elif token.group() == '}':
                depth -= 1
            if not depth:
                yield match[1].strip('"'), text[match.end():token.start()]
                position = token.end()
                break
        else:
            raise ValueError('Unclosed Liberty group: ' + match[1])


def library_pins(path):
    text = path.read_text()
    unit = re.search(r'capacitive_load_unit\s*\(\s*([0-9.eE+-]+)\s*,\s*([a-zA-Z]+)\s*\)', text)
    if not unit or unit[2].lower() not in {'ff', 'pf'}:
        raise ValueError('Unsupported or missing Liberty capacitance unit')
    scale = float(unit[1]) * {'ff': 0.001, 'pf': 1.0}[unit[2].lower()]
    result = {}
    for name, cell in groups(text, 'cell'):
        pins = {}
        for pin, body in groups(cell, 'pin'):
            attrs = dict(re.findall(r'\b(direction|function|capacitance|rise_capacitance|'
                                    r'fall_capacitance|max_capacitance)\s*:\s*([^;]+);', body))
            pins[pin] = {k: v.strip().strip('"') for k, v in attrs.items()}
            for key in ['capacitance', 'rise_capacitance', 'fall_capacitance', 'max_capacitance']:
                if key in pins[pin]:
                    pins[pin][key] = str(float(pins[pin][key]) * scale)
        result[name] = pins
    if not result:
        raise ValueError('No Liberty cells')
    return result


def pin_capacitance(pins, cell, pin):
    attrs = pins[cell][pin]
    values = [float(attrs[k]) for k in ['capacitance', 'rise_capacitance',
                                       'fall_capacitance'] if k in attrs]
    if not values:
        raise ValueError(f'Missing input capacitance: {cell}/{pin}')
    return max(values)


def connections(module):
    drivers, sinks = {}, {}
    for name, cell in module['cells'].items():
        for port, bits in cell['connections'].items():
            direction = cell['port_directions'][port]
            for index, bit in enumerate(bits):
                if not isinstance(bit, int):
                    continue
                if direction == 'output':
                    if bit in drivers:
                        raise ValueError(f'Multiple mapped drivers on bit {bit}')
                    drivers[bit] = (name, port)
                elif direction == 'input':
                    sinks.setdefault(bit, []).append((name, port, index))
                else:
                    raise ValueError('Inout pins require an explicit repair policy')
    for port, entry in module['ports'].items():
        if entry['direction'] == 'output':
            for index, bit in enumerate(entry['bits']):
                if isinstance(bit, int):
                    sinks.setdefault(bit, []).append((None, port, index))
    return drivers, sinks


def repair(module, pins, *, fanout=0, headroom=1.0, buffer_cell='BUF_X2',
           output_load=0.01):
    original = copy.deepcopy(module)
    cells = module['cells']
    drivers, sinks = connections(module)
    # Zero disables the optional project fanout policy. Library capacitance
    # limits still apply to every mapped driver. The finite working bound only
    # sizes the tree; no original net has more sinks than this value.
    assert fanout == 0 or fanout >= 2
    connection_limit = fanout or max((len(entries) for entries in sinks.values()), default=0) + 1
    buffer = pins[buffer_cell]
    assert buffer['A']['direction'] == 'input'
    assert buffer['Z']['direction'] == 'output' and buffer['Z']['function'] == 'A'
    buffer_input_cap = pin_capacitance(pins, buffer_cell, 'A')
    buffer_limit = float(buffer['Z']['max_capacitance']) * headroom
    bit_numbers = [b for n in module['netnames'].values() for b in n['bits']
                   if isinstance(b, int)]
    next_bit = max(bit_numbers) + 1
    added, repaired, constant_drivers = [], [], []
    canonical = {}

    def load(sink):
        name, port, _ = sink
        return output_load if name is None else pin_capacitance(pins, cells[name]['type'], port)

    def distribute(driver, loads, capacity, original_bit):
        nonlocal next_bit
        if len(loads) <= connection_limit and sum(map(load, loads)) <= capacity:
            for name, port, index in loads:
                if name is None:
                    module['ports'][port]['bits'][index] = driver
                    module['netnames'][port]['bits'][index] = driver
                else:
                    cells[name]['connections'][port][index] = driver
            return
        branch_limit = min(connection_limit, int(capacity / buffer_input_cap))
        if branch_limit < 1:
            raise ValueError(f'Driver cannot support buffer tree: bit {original_bit}')
        needed = max(math.ceil(len(loads) / connection_limit),
                     math.ceil(sum(map(load, loads)) / buffer_limit), 2)
        branches = min(branch_limit, needed, len(loads))
        if len(loads) == 1 and load(loads[0]) > buffer_limit:
            raise ValueError(f'Single load exceeds buffer budget: {loads}')
        # Greedy weighted groups keep electrically unequal pins balanced.
        buckets = [[] for _ in range(branches)]
        weights = [0.0] * branches
        for sink in sorted(loads, key=load, reverse=True):
            choice = min(range(branches), key=lambda i: (weights[i], len(buckets[i])))
            buckets[choice].append(sink)
            weights[choice] += load(sink)
        for bucket in buckets:
            name = f'electrical_buffer_{len(added)}'
            assert name not in cells
            bit = next_bit
            next_bit += 1
            cells[name] = {'hide_name': 0, 'type': buffer_cell, 'parameters': {},
                           'attributes': {}, 'port_directions': {'A': 'input', 'Z': 'output'},
                           'connections': {'A': [driver], 'Z': [bit]}}
            module['netnames'][name + '_out'] = {'hide_name': 0, 'bits': [bit], 'attributes': {}}
            added.append(name)
            canonical[bit] = original_bit
            distribute(bit, bucket, buffer_limit, original_bit)

    for bit, (name, port) in drivers.items():
        loads = sinks.get(bit, [])
        attrs = pins[cells[name]['type']][port]
        if not loads:
            continue
        if 'max_capacitance' in attrs:
            limit = float(attrs['max_capacitance']) * headroom
        elif attrs.get('function') in {'0', '1'}:
            # Nangate tie cells specify no output-capacitance bound. Apply the
            # project fanout rule; do not invent a Liberty limit for them.
            constant_drivers.append(name)
            if not fanout:
                continue
            limit = connection_limit * buffer_input_cap
        else:
            raise ValueError(f'Missing output limit: {cells[name]["type"]}/{port}')
        if len(loads) <= connection_limit and sum(map(load, loads)) <= limit:
            continue
        repaired.append({'driver': name, 'port': port, 'loads': len(loads),
                         'load_pf': sum(map(load, loads))})
        distribute(bit, loads, limit, bit)

    # Collapse only the newly inserted, verified non-inverting cells. Every old
    # instance, sequential pin, top-level port and connection must be identical.
    collapsed = copy.deepcopy(cells)
    for name in added:
        cell = collapsed.pop(name)
        source = cell['connections']['A'][0]
        target = cell['connections']['Z'][0]
        assert canonical[target] == canonical.get(source, source)
    for cell in collapsed.values():
        for port, bits in cell['connections'].items():
            cell['connections'][port] = [canonical.get(bit, bit) for bit in bits]
    assert collapsed == original['cells'], 'Original cell connections changed'
    collapsed_ports = copy.deepcopy(module['ports'])
    for entry in collapsed_ports.values():
        entry['bits'] = [canonical.get(bit, bit) for bit in entry['bits']]
    assert collapsed_ports == original['ports'], 'Top-level port functions changed'
    new_drivers, new_sinks = connections(module)
    worst_fanout = 0
    for bit, (name, port) in new_drivers.items():
        loads = new_sinks.get(bit, [])
        worst_fanout = max(worst_fanout, len(loads))
        if fanout:
            assert len(loads) <= fanout, (name, len(loads))
        attrs = pins[cells[name]['type']][port]
        total = sum(map(load, loads))
        if 'max_capacitance' in attrs:
            assert total <= float(attrs['max_capacitance']) + 1e-12, (name, total)
    return {'buffer_cell': buffer_cell, 'buffer_count': len(added),
            'project_fanout_limit': fanout or None,
            'repaired_driver_count': len(repaired), 'repaired_drivers': repaired,
            'constant_drivers_without_liberty_cap_limit': constant_drivers,
            'output_load_pf_per_port': output_load,
            'maximum_cell_output_fanout': worst_fanout,
            'capacitance_headroom_fraction': headroom,
            'structural_equivalence': 'passed', 'static_load_audit': 'passed',
            'scope': 'Mapped drivers; external clock/data input drive is defined by SDC'}


def quote(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--netlist', type=Path, required=True)
    parser.add_argument('--liberty', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--top', default='riscv_core_reset_boundary')
    parser.add_argument('--fanout', type=int, default=0,
                        help='Optional project fanout cap; 0 uses electrical limits only')
    parser.add_argument('--buffer-cell', default='BUF_X2')
    parser.add_argument('--headroom', type=float, default=1.0)
    parser.add_argument('--output-load', type=float, default=0.01)
    args = parser.parse_args()
    assert (args.fanout == 0 or args.fanout >= 2) and 0 < args.headroom <= 1 and args.output_load >= 0
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    netlist = out / f'{args.top}.netlist.v'
    assert args.netlist.resolve() != netlist

    def yosys(name, script):
        path = out / (name + '.ys')
        path.write_text(script)
        with (out / (name + '.log')).open('w') as log:
            subprocess.run(['yosys', '-Q', '-T', '-s', str(path)], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=600)

    yosys('read', f'read_liberty -lib {quote(args.liberty.resolve())}\n'
          f'read_verilog {quote(args.netlist.resolve())}\nhierarchy -top {args.top}\n'
          f'write_json {quote(out / "before.json")}\n')
    design = json.loads((out / 'before.json').read_text())
    summary = repair(design['modules'][args.top], library_pins(args.liberty),
                     fanout=args.fanout, headroom=args.headroom, buffer_cell=args.buffer_cell,
                     output_load=args.output_load)
    (out / 'buffered.json').write_text(json.dumps(design))
    yosys('write', f'read_json {quote(out / "buffered.json")}\nhierarchy -top {args.top}\n'
          f'select {args.top}\ntee -o {quote(out / "synth_check.txt")} check -mapped\n'
          f'tee -o {quote(out / "synth_stat.txt")} stat -liberty {quote(args.liberty.resolve())}\n'
          f'write_verilog -noattr -noexpr -nohex -nodec {quote(netlist)}\n')
    summary.update({'source_netlist': str(args.netlist.resolve()),
                    'source_sha256': hashlib.sha256(args.netlist.read_bytes()).hexdigest(),
                    'netlist_sha256': hashlib.sha256(netlist.read_bytes()).hexdigest()})
    (out / 'electrical-repair.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({k: v for k, v in summary.items() if k != 'repaired_drivers'}, indent=2))


if __name__ == '__main__':
    main()
