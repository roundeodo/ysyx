#!/usr/bin/env python3
"""Shorten failing timing paths without changing original cell functions.

Only buffers inserted by repair_mapped_fanout may be bypassed. A critical
sink can reconnect to its previous driver when that driver's load and fanout
remain within budget. Every original pin is checked after collapsing buffers.
"""
import copy
import re

from repair_mapped_fanout import connections, pin_capacitance


def failing_path_inputs(report, cells):
    """Read input pins from detailed violated paths, preserving report order."""
    pending, result = [], []
    for line in report.splitlines():
        row = [field.strip() for field in line.split('|')[1:-1]]
        if not row:
            continue
        if row[0] == 'Point':
            pending = []
        match = re.fullmatch(r'(.+):([^: ]+) \([^)]+\)', row[0])
        if match:
            name, pin = match.groups()
            if name in cells and cells[name]['port_directions'].get(pin) == 'input':
                pending.append((name, pin))
        if row[0] == 'slack (VIOLATED)':
            for entry in pending:
                if entry not in result:
                    result.append(entry)
    return result


def audit(original, module, pins, fanout, output_load):
    cells = module['cells']
    added = set(cells) - set(original['cells'])
    roots = {}
    for name in added:
        cell = cells[name]
        definition = pins[cell['type']]
        assert set(cell['connections']) == {'A', 'Z'}
        assert definition['Z']['function'] == 'A'
        roots[cell['connections']['Z'][0]] = cell['connections']['A'][0]

    def collapse(bit):
        seen = set()
        while bit in roots:
            assert bit not in seen, 'Buffer cycle'
            seen.add(bit)
            bit = roots[bit]
        return bit

    assert set(original['cells']) <= set(cells), 'Original cell removed'
    for name, expected in original['cells'].items():
        actual = copy.deepcopy(cells[name])
        actual['connections'] = {pin: [collapse(bit) for bit in bits]
                                 for pin, bits in actual['connections'].items()}
        assert actual == expected, 'Original cell changed: ' + name
    ports = copy.deepcopy(module['ports'])
    for port in ports.values():
        port['bits'] = [collapse(bit) for bit in port['bits']]
    assert ports == original['ports'], 'External port changed'
    drivers, sinks = connections(module)
    worst = 0
    for bit, (name, pin) in drivers.items():
        loads = sinks.get(bit, [])
        worst = max(worst, len(loads))
        if fanout:
            assert len(loads) <= fanout, (name, len(loads))
        total = sum(output_load if target is None else
                    pin_capacitance(pins, cells[target]['type'], port)
                    for target, port, _ in loads)
        bound = pins[cells[name]['type']][pin].get('max_capacitance')
        if bound is not None:
            assert total <= float(bound) + 1e-12, (name, total, bound)
    return worst


def refine(original, module, pins, report, *, fanout=16, headroom=0.65,
           output_load=0.01):
    cells = module['cells']
    added = set(cells) - set(original['cells'])
    drivers, sinks = connections(module)
    changes = []

    def load(entries):
        return sum(output_load if name is None else
                   pin_capacitance(pins, cells[name]['type'], port)
                   for name, port, _ in entries)

    for name, pin in failing_path_inputs(report, cells):
        # Clock and asynchronous control paths require separate reset/CTS work.
        if pin in {'CK', 'RN', 'SN'} or name in added:
            continue
        for index, bit in enumerate(list(cells[name]['connections'][pin])):
            while bit in drivers:
                buffer_name, _ = drivers[bit]
                if buffer_name not in added:
                    break
                buffer = cells[buffer_name]
                assert pins[buffer['type']]['Z']['function'] == 'A'
                source = buffer['connections']['A'][0]
                if source not in drivers:
                    break  # Do not change an external input's drive budget.
                driver, output_pin = drivers[source]
                bound = pins[cells[driver]['type']][output_pin].get('max_capacitance')
                entry = (name, pin, index)
                projected = sinks.get(source, []) + [entry]
                if (bound is None or (fanout and len(projected) > fanout) or
                        load(projected) > float(bound) * headroom):
                    break
                cells[name]['connections'][pin][index] = source
                sinks[bit].remove(entry)
                sinks.setdefault(source, []).append(entry)
                changes.append({'sink': name, 'pin': pin, 'index': index,
                                'bypassed_buffer': buffer_name, 'driver': driver,
                                'driver_load_pf': load(projected),
                                'driver_fanout': len(projected)})
                bit = source

    worst = audit(original, module, pins, fanout, output_load)
    return {'changes': changes, 'structural_equivalence': 'passed',
            'static_load_audit': 'passed', 'maximum_cell_output_fanout': worst}
