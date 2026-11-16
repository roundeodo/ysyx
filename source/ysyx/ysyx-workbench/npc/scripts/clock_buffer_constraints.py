#!/usr/bin/env python3
"""Model 1:1 gated core clocks past buffers skipped by the bundled iSTA.

This Nangate45 flow uses one ideal root clock. The affected iSTA stops at an
ICG output when its next sink is a buffer rather than a sequential clock pin.
The generated clock preserves the root period and phase; it adds no timing
exception and does not change the netlist or remove clock-gating checks.
"""
import argparse
import hashlib
import json
from pathlib import Path


def clock_buffer_targets(module):
    cells = module['cells']
    root_bits = module['ports']['clk_i']['bits']
    if len(root_bits) != 1:
        raise ValueError('Expected one scalar core clock input')
    root = root_bits[0]
    drivers = {}
    for name, cell in cells.items():
        for pin, direction in cell['port_directions'].items():
            if direction == 'output':
                for bit in cell['connections'][pin]:
                    if isinstance(bit, int):
                        if bit in drivers:
                            raise ValueError(f'Multiple mapped drivers for net {bit}')
                        drivers[bit] = (name, pin)

    def is_buffer(cell):
        return cell['type'].startswith(('BUF_', 'CLKBUF_'))

    def check_root(bit):
        seen = set()
        while bit != root:
            if bit in seen or bit not in drivers:
                raise ValueError('Clock branch is cyclic or has no core-clock source')
            seen.add(bit)
            name, pin = drivers[bit]
            cell = cells[name]
            if is_buffer(cell) and pin == 'Z':
                bit = cell['connections']['A'][0]
            elif cell['type'].startswith('CLKGATE_') and pin == 'GCK':
                bit = cell['connections']['CK'][0]
            else:
                raise ValueError(f'Clock phase/source needs explicit constraints: {name}/{pin}')

    targets = []
    gates = set()
    for name, cell in cells.items():
        if not is_buffer(cell):
            continue
        source = drivers.get(cell['connections']['A'][0])
        if source is None:
            continue
        gate_name, pin = source
        gate = cells[gate_name]
        if not gate['type'].startswith('CLKGATE_') or pin != 'GCK':
            continue
        check_root(gate['connections']['CK'][0])
        target = name + ':A'
        if any(ch.isspace() or ch in '{}\\' for ch in target):
            raise ValueError(f'Unsupported Tcl pin spelling: {target}')
        targets.append(target)
        gates.add(gate_name)
    return sorted(targets), sorted(gates)


def render_constraints(targets):
    text = '# Preserve the phase and period of gated branches of the ideal core clock.\n'
    if targets:
        text += 'create_generated_clock -name buffered_core_clock \\\n'
        text += '    -source [get_ports clk_i] -divide_by 1 \\\n'
        text += '    [get_pins {' + ' '.join(targets) + '}]\n'
    return text


def write_constraints(netlist_json, output):
    design = json.loads(netlist_json.read_text())
    module = design['modules']['riscv_core_reset_boundary']
    targets, gates = clock_buffer_targets(module)
    output.write_text(render_constraints(targets))
    record = {'source_sha256': hashlib.sha256(netlist_json.read_bytes()).hexdigest(),
              'root_clock': 'core_clock', 'divide_by': 1, 'phase_inverted': False,
              'buffer_input_pins': targets, 'upstream_clock_gates': gates,
              'scope': 'Nangate45 single ideal core clock; no timing exceptions'}
    output.with_suffix('.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--netlist-json', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    record = write_constraints(args.netlist_json, args.output)
    print('Clock coverage: generated 1:1 root-clock constraints for',
          len(record['buffer_input_pins']), 'buffer inputs')


if __name__ == '__main__':
    main()
