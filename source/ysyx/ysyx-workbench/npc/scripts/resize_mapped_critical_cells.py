#!/usr/bin/env python3
"""Increase a few critical combinational drivers without changing logic or pins."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess

from repair_mapped_fanout import groups, library_pins, quote


CELL_FAMILY = re.compile(
    r'(BUF|INV|(?:NAND|NOR|AND|OR)[234]|(?:AOI|OAI)(?:21|22|211)|(?:XOR|XNOR)2|MUX2)_X(1|2|4|8|16)')


def equivalent_larger_cells(library):
    """Require matching pin directions/functions and exclude state-holding cells."""
    pins = library_pins(library)
    families = {}
    for name, body in groups(library.read_text(), 'cell'):
        match = CELL_FAMILY.fullmatch(name)
        if match and not re.search(r'\b(?:ff|latch|statetable)\s*\(', body):
            families[name] = (match[1], int(match[2]))

    def signature(name):
        return {p: (a['direction'], a.get('function')) for p, a in pins[name].items()}

    replacements = {}
    for name, (family, strength) in families.items():
        choices = sorted((s, other) for other, (f, s) in families.items()
                         if f == family and strength < s <= 8 and signature(other) == signature(name))
        if choices:
            replacements[name] = choices[0][1]
    return replacements


def critical_drivers(report, cells, replacements, minimum_arc_ns=0.045):
    """Nominate real output arcs from violated paths, not input pins or passing paths."""
    pending, critical = {}, {}
    for line in report.splitlines():
        row = [x.strip() for x in line.split('|')[1:-1]]
        if not row:
            continue
        if row[0] == 'Point':
            pending = {}
        match = re.fullmatch(r'(.+):([^: ]+) \(([^)]+)\)', row[0])
        if match and len(row) == 8:
            name, pin, kind = match.groups()
            cell = cells.get(name)
            if (cell and cell['type'] == kind and kind in replacements and
                    cell['port_directions'].get(pin) == 'output'):
                delay = float(row[6])
                if delay >= minimum_arc_ns:
                    pending[name] = max(pending.get(name, 0), delay)
        if row[0] == 'slack (VIOLATED)':
            for name, delay in pending.items():
                critical[name] = max(critical.get(name, 0), delay)
    return sorted(critical.items(), key=lambda item: (-item[1], item[0]))


def resize(original, top, report, replacements, max_cells, minimum_arc_ns=0.045):
    result = copy.deepcopy(original)
    cells = result['modules'][top]['cells']
    changes = []
    for name, delay in critical_drivers(report, cells, replacements, minimum_arc_ns)[:max_cells]:
        cell = cells[name]
        before = cell['type']
        cell['type'] = replacements[before]
        changes.append({'instance': name, 'before': before, 'after': cell['type'],
                        'reported_arc_ns': delay})
    # Check the complete design, not only each nominated output pin.
    restored = copy.deepcopy(result)
    for change in changes:
        restored['modules'][top]['cells'][change['instance']]['type'] = change['before']
    assert restored == original, 'A change other than equivalent drive strength occurred'
    return result, changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--liberty', type=Path, required=True)
    parser.add_argument('--max-cells', type=int, default=12)
    parser.add_argument('--minimum-arc-ns', type=float, default=0.045,
                        help='Minimum reported output-arc delay on a failing path')
    args = parser.parse_args()
    assert args.max_cells > 0 and args.minimum_arc_ns > 0
    previous, output = args.previous.resolve(), args.output.resolve()
    if output.exists():
        raise SystemExit('Preserve previous evidence: ' + str(output))
    acceptance = json.loads((previous / 'acceptance.json').read_text())
    assert not acceptance['passed'], 'No repair needed'
    assert acceptance['reset_and_connection_audits_passed']
    assert acceptance['capacitance']['passed'] and acceptance['transition']['passed']
    assert all(acceptance['timing']['groups'][key]['slack_ns'] >= 0
               for key in ['data_min', 'gating_min']), 'Do not repair a hold failure by upsizing'
    top = json.loads((previous / 'provenance.json').read_text())['top']
    original_path = previous / 'before.json'
    result, changes = resize(json.loads(original_path.read_text()), top,
                             (previous / (top + '.rpt')).read_text(),
                             equivalent_larger_cells(args.liberty), args.max_cells, args.minimum_arc_ns)
    if not changes:
        raise SystemExit('No eligible critical combinational drivers')
    output.mkdir(parents=True)
    (output / 'resized.json').write_text(json.dumps(result))
    script = output / 'write.ys'
    netlist = output / 'resized.v'
    script.write_text(
        f'read_json {quote(output / "resized.json")}\nhierarchy -top {top}\nselect {top}\n'
        f'tee -o {quote(output / "synth_check.txt")} check -mapped\n'
        f'tee -o {quote(output / "synth_stat.txt")} stat -liberty {quote(args.liberty)}\n'
        f'write_verilog -noattr -noexpr -nohex -nodec {quote(netlist)}\n')
    with (output / 'write.log').open('w') as log:
        subprocess.run(['yosys', '-Q', '-T', '-s', str(script)], stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    audit = {'previous': str(previous), 'original_sha256': sha(original_path),
             'library_sha256': sha(args.liberty), 'netlist_sha256': sha(netlist),
             'changes': changes, 'minimum_arc_ns': args.minimum_arc_ns,
             'combinational_pin_functions_equal': True,
             'all_connections_parameters_and_other_cells_equal': True}
    (output / 'audit.json').write_text(json.dumps(audit, indent=2) + '\n')
    print(f'Resized {len(changes)} combinational drivers; complete qualification still required')


if __name__ == '__main__':
    main()
