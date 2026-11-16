#!/usr/bin/env python3
"""Check drive-only repair boundaries and qualification failure propagation."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

NPC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NPC / 'scripts'))
from resize_mapped_critical_cells import equivalent_larger_cells, resize
import qualify_mapped_sta

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--liberty', type=Path, required=True)
args = parser.parse_args()
replacements = equivalent_larger_cells(args.liberty)
assert replacements['BUF_X1'] == 'BUF_X2'
assert replacements['NAND4_X1'] == 'NAND4_X2'
assert not any(name.startswith(('DFF', 'SDFF', 'CLKGATE', 'LATCH')) for name in replacements)

cells = {
    'critical': {'type': 'BUF_X1', 'port_directions': {'A': 'input', 'Z': 'output'},
                 'connections': {'A': [2], 'Z': [3]}, 'parameters': {}, 'attributes': {'keep': '1'}},
    'passing': {'type': 'BUF_X1', 'port_directions': {'A': 'input', 'Z': 'output'},
                'connections': {'A': [3], 'Z': [4]}, 'parameters': {}, 'attributes': {}},
    'state': {'type': 'DFF_X1', 'port_directions': {'D': 'input', 'Q': 'output', 'CK': 'input'},
              'connections': {'D': [4], 'Q': [5], 'CK': [1]}, 'parameters': {}, 'attributes': {}}
}
original = {'modules': {'top': {'cells': cells, 'ports': {'out': {'direction': 'output', 'bits': [5]}}}}}
unchanged = copy.deepcopy(original)
report = '''| Point | Fanout | Capacitance | Resistance | Transition | Delta Delay | Incr | Path |
| passing:Z (BUF_X1) | | .1 | 0 | .1 | | .300 | .300r |
| slack (MET) | | | | | | | .1 |
| Point | Fanout | Capacitance | Resistance | Transition | Delta Delay | Incr | Path |
| critical:A (BUF_X1) | | .1 | 0 | .1 | | .900 | .900r |
| critical:Z (BUF_X1) | | .1 | 0 | .1 | | .120 | 1.020r |
| state:Q (DFF_X1) | | .1 | 0 | .1 | | .500 | 1.520r |
| slack (VIOLATED) | | | | | | | -.1 |
'''
result, changes = resize(original, 'top', report, replacements, 12)
assert original == unchanged
assert changes == [{'instance': 'critical', 'before': 'BUF_X1', 'after': 'BUF_X2', 'reported_arc_ns': .120}]
expected = copy.deepcopy(original)
expected['modules']['top']['cells']['critical']['type'] = 'BUF_X2'
assert result == expected, 'Pins, state, passing paths and attributes must remain unchanged'

# A fine pass can repair a remaining short output arc while the same passing
# path, input pin and sequential cell stay excluded.
short_report = report.replace('.120 | 1.020r', '.040 | .940r')
coarse_result, coarse_changes = resize(original, 'top', short_report, replacements, 12)
assert coarse_result == original and not coarse_changes
fine_result, fine_changes = resize(original, 'top', short_report, replacements, 12, 0.035)
assert fine_result == expected
assert fine_changes == [dict(changes[0], reported_arc_ns=.040)]
assert original == unchanged

# Exercise the orchestration independently of slow EDA binaries. Actual netlist
# qualification and the cell-function audit are separately recorded in the run.
for label, statuses, sizing_fails, expected_pass in [
        ('initial_pass', [(0, True)], False, True),
        ('repaired_pass', [(1, False), (0, True)], False, True),
        ('fine_pass', [(1, False)] * 3 + [(0, True)], False, True),
        ('all_fail', [(1, False)] * 4, False, False),
        ('repair_fail', [(1, False)], True, False),
        ('process_error', [(1, True)], True, False)]:
    with tempfile.TemporaryDirectory(prefix='npc-drive-test-') as temp:
        root = Path(temp)
        netlist = root / 'input.v'
        netlist.write_text('module test; endmodule\n')
        out = root / 'result'
        remaining = iter(statuses)
        def run(command, **kwargs):
            dest = Path(command[command.index('--output') + 1])
            if command[1].endswith('resize_mapped_critical_cells.py'):
                if sizing_fails:
                    return subprocess.CompletedProcess(command, 1)
                dest.mkdir()
                (dest / 'resized.v').write_text(netlist.read_text())
                return subprocess.CompletedProcess(command, 0)
            code, accepted = next(remaining)
            dest.mkdir()
            (dest / 'acceptance.json').write_text(json.dumps({'passed': accepted}))
            return subprocess.CompletedProcess(command, code)
        argv = ['qualify_mapped_sta.py', '--netlist', str(netlist), '--toolflow', str(root),
                '--sdc', str(root / 'test.sdc'), '--output', str(out)]
        with patch.object(sys, 'argv', argv), patch.object(subprocess, 'run', run):
            try:
                qualify_mapped_sta.main()
            except SystemExit as exc:
                assert (exc.code == 0) == expected_pass, (label, exc.code)
            else:
                raise AssertionError('Qualification did not return an explicit status')
        summary = json.loads((out / 'qualification-summary.json').read_text())
        assert summary['passed'] == expected_pass
        repairs = [step['command'] for step in summary['attempts']
                   if step['operation'] == 'drive strength']
        assert len(repairs) <= 3
        for index, command in enumerate(repairs, 1):
            if index == 3:
                assert command[command.index('--minimum-arc-ns') + 1] == '0.035'
            else:
                assert '--minimum-arc-ns' not in command
        assert json.loads((out / 'acceptance.json').read_text())['passed'] == expected_pass
        print('PASS', label)
print('PASS critical drive boundaries: actual Liberty functions, pins, state and failed qualification')
