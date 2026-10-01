#!/usr/bin/env python3
"""Check that shortening a critical branch preserves logic and load budgets."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from refine_mapped_buffers import audit, refine


def cell(kind, inputs, output):
    ports = dict(inputs, Z=[output])
    return {'type': kind, 'connections': ports, 'parameters': {}, 'attributes': {},
            'port_directions': {pin: 'output' if pin == 'Z' else 'input' for pin in ports}}


class BufferRefinementTests(unittest.TestCase):
    def setUp(self):
        self.pins = {
            'BUF': {'A': {'direction': 'input', 'capacitance': '0.002'},
                    'Z': {'direction': 'output', 'function': 'A', 'max_capacitance': '0.1'}},
            'GATE': {'E': {'direction': 'input', 'capacitance': '0.003'},
                     'Z': {'direction': 'output', 'function': 'E', 'max_capacitance': '0.1'}}}
        self.original = {'cells': {'driver': cell('BUF', {'A': [1]}, 2),
                                   'critical': cell('GATE', {'E': [2]}, 3),
                                   'other': cell('GATE', {'E': [2]}, 4)},
                         'ports': {'in': {'direction': 'input', 'bits': [1]},
                                   'out': {'direction': 'output', 'bits': [3]}}}
        self.module = copy.deepcopy(self.original)
        self.module['cells']['inserted'] = cell('BUF', {'A': [2]}, 5)
        for name in ['critical', 'other']:
            self.module['cells'][name]['connections']['E'] = [5]
        self.report = '| Point |\n| critical:E (GATE) |\n| slack (VIOLATED) |'

    def test_only_critical_sink_moves_and_all_original_pins_match(self):
        result = refine(self.original, self.module, self.pins, self.report)
        self.assertEqual(len(result['changes']), 1)
        self.assertEqual(self.module['cells']['critical']['connections']['E'], [2])
        self.assertEqual(self.module['cells']['other']['connections']['E'], [5])
        self.assertEqual(audit(self.original, self.module, self.pins, 16, 0.01), 2)
        self.module['cells']['critical']['connections']['E'] = [1]
        with self.assertRaisesRegex(AssertionError, 'Original cell changed'):
            audit(self.original, self.module, self.pins, 16, 0.01)

    def test_capacitance_fanout_and_passing_paths_block_bypass(self):
        for limit, fanout, report in [(0.007, 16, self.report),
                                     (0.1, 1, self.report),
                                     (0.1, 16, self.report.replace('VIOLATED', 'MET'))]:
            with self.subTest(limit=limit, fanout=fanout):
                pins = copy.deepcopy(self.pins)
                pins['BUF']['Z']['max_capacitance'] = str(limit)
                # The existing two-sink branch needs a fanout budget of two;
                # saturate the parent separately for the fanout rejection case.
                module = copy.deepcopy(self.module)
                original = copy.deepcopy(self.original)
                if fanout == 1:
                    module['cells'].pop('other')
                    original['cells'].pop('other')
                result = refine(original, module, pins, report, fanout=fanout)
                self.assertEqual(result['changes'], [])
                self.assertEqual(module['cells']['critical']['connections']['E'], [5])


if __name__ == '__main__':
    unittest.main()
