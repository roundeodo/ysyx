#!/usr/bin/env python3
"""Check clock-root ownership and reproduce ICG-to-buffer clock coverage in iSTA."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from clock_buffer_constraints import clock_buffer_targets, render_constraints
from check_sta_acceptance import clock_coverage_report


def fixture():
    def cell(kind, inputs, outputs):
        return {'type': kind, 'connections': {**inputs, **outputs},
                'port_directions': {**{p: 'input' for p in inputs},
                                    **{p: 'output' for p in outputs}}}
    return {'ports': {'clk_i': {'bits': [1]}}, 'cells': {
        'gate_cell': cell('CLKGATE_X1', {'CK': [1], 'E': [2]}, {'GCK': [3]}),
        'leaf_buffer': cell('BUF_X2', {'A': [3]}, {'Z': [4]}),
        'second_buffer': cell('BUF_X2', {'A': [3]}, {'Z': [5]}),
        'next_buffer': cell('BUF_X2', {'A': [4]}, {'Z': [6]}),
        'data_buffer': cell('BUF_X2', {'A': [2]}, {'Z': [7]})}}


class ClockConstraintsTests(unittest.TestCase):
    def test_only_first_clock_buffer_inputs_are_clock_sources(self):
        targets, gates = clock_buffer_targets(fixture())
        self.assertEqual(targets, ['leaf_buffer:A', 'second_buffer:A'])
        self.assertEqual(gates, ['gate_cell'])

    def test_foreign_clock_is_not_silently_changed_to_core_clock(self):
        module = fixture()
        module['cells']['gate_cell']['connections']['CK'] = [90]
        with self.assertRaises(ValueError):
            clock_buffer_targets(module)

    def test_inversion_needs_an_explicit_phase_model(self):
        module = fixture()
        module['cells']['gate_cell']['connections']['CK'] = [8]
        module['cells']['inverter'] = {'type': 'INV_X1',
            'connections': {'A': [1], 'ZN': [8]},
            'port_directions': {'A': 'input', 'ZN': 'output'}}
        with self.assertRaises(ValueError):
            clock_buffer_targets(module)


def probe(toolflow, parent):
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent)).resolve()
    toolflow = toolflow.resolve()
    netlist = '''module clock_probe(clk_i, enable_i, data_i, direct_o, buffered_o, second_o, returned_o);
input clk_i;
input enable_i;
input data_i;
output direct_o;
output buffered_o;
output second_o;
output returned_o;
wire gated_clock;
wire buffered_clock;
wire second_clock;
CLKGATE_X1 gate_cell (.CK(clk_i), .E(enable_i), .GCK(gated_clock));
DFF_X1 direct_ff (.CK(gated_clock), .D(data_i), .Q(direct_o));
BUF_X2 leaf_buffer (.A(gated_clock), .Z(buffered_clock));
DFF_X1 buffered_ff (.CK(buffered_clock), .D(direct_o), .Q(buffered_o));
BUF_X2 second_buffer (.A(gated_clock), .Z(second_clock));
DFF_X1 second_ff (.CK(second_clock), .D(buffered_o), .Q(second_o));
DFF_X1 returned_ff (.CK(gated_clock), .D(second_o), .Q(returned_o));
endmodule
'''
    records = []
    for name in ('baseline', 'covered'):
        directory = output / name
        directory.mkdir()
        (directory / 'top.v').write_text(netlist)
        sdc = '''create_clock -name core_clock -period 2.0 [get_ports clk_i]
set_input_delay 0.1 -clock core_clock [get_ports enable_i]
set_input_delay 0.1 -clock core_clock [get_ports data_i]
set_output_delay 0.1 -clock core_clock [all_outputs]
set_input_transition 0.1 [all_inputs]
'''
        if name == 'covered':
            sdc += render_constraints(clock_buffer_targets(fixture())[0])
        (directory / 'constraints.sdc').write_text(sdc)
        script = (f'set_design_workspace {directory}\nread_netlist {directory}/top.v\n'
                  f'read_liberty {toolflow}/pdk/nangate45/lib/Nangate45_typ.lib\n'
                  f'link_design clock_probe\nread_sdc {directory}/constraints.sdc\n'
                  'report_timing -max_path 20\n')
        (directory / 'run.tcl').write_text(script)
        command = [str(toolflow / 'bin/iEDA'), '-script', str(directory / 'run.tcl')]
        with (directory / 'sta.log').open('w') as log:
            result = subprocess.run(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT,
                                    env=dict(os.environ, OMP_NUM_THREADS='1'), timeout=240)
        text = (directory / 'sta.log').read_text()
        if result.returncode or 'The timing engine run success.' not in text:
            raise RuntimeError(f'Clock probe did not complete: {directory}')
        coverage = clock_coverage_report(directory / 'sta.log')
        if name == 'covered':
            assert coverage['passed'], coverage
            report = (directory / 'clock_probe.rpt').read_text()
            for endpoint in ('direct_ff:D', 'buffered_ff:D', 'second_ff:D', 'returned_ff:D'):
                assert endpoint in report, endpoint
        records.append({'name': name, 'command': command, 'clock_coverage': coverage})
    # A future fixed iSTA is also allowed to time the baseline correctly.
    (output / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
    print('PASS clock propagation probe:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolflow', type=Path)
    parser.add_argument('--output', type=Path, default=Path('build/tests/clock-coverage'))
    args = parser.parse_args()
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(ClockConstraintsTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.toolflow:
        probe(args.toolflow, args.output)
