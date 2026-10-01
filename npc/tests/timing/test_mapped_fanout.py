#!/usr/bin/env python3
"""Exercise unequal loads, multiple roots and external aliases independently."""
import copy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from repair_mapped_fanout import library_pins, repair


class FanoutRepairTests(unittest.TestCase):
    def test_liberty_units_and_quoted_braces(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.lib'
            path.write_text('''library(test) { capacitive_load_unit(1, ff);
              cell(BUF_X2) { comment : "ignore { and }";
                pin(A) { direction : input; capacitance : 2.0; }
                pin(Z) { direction : output; function : "A"; max_capacitance : 120; }
              }
            }''')
            pins = library_pins(path)
            self.assertEqual(float(pins['BUF_X2']['A']['capacitance']), 0.002)
            self.assertEqual(float(pins['BUF_X2']['Z']['max_capacitance']), 0.12)

    def test_all_old_pins_keep_their_original_driver(self):
        pins = {
            'BUF_X2': {'A': {'direction': 'input', 'capacitance': '0.002'},
                       'Z': {'direction': 'output', 'function': 'A', 'max_capacitance': '0.12'}},
            'REG': {'D': {'direction': 'input', 'capacitance': '0.003'},
                    'CK': {'direction': 'input', 'capacitance': '0.002'},
                    'Q': {'direction': 'output', 'max_capacitance': '0.06'}},
        }
        cells = {}
        for index in range(137):
            cells[f'reg_{index}'] = {
                'type': 'REG', 'parameters': {}, 'attributes': {},
                'port_directions': {'D': 'input', 'CK': 'input', 'Q': 'output'},
                'connections': {'D': [2 if index else 1], 'CK': [3], 'Q': [index + 2]},
            }
        module = {'cells': cells, 'ports': {'in': {'direction': 'input', 'bits': [1]},
                                          'out': {'direction': 'output', 'bits': [2]}},
                  'netnames': {f'n{i}': {'bits': [i]} for i in range(1, 139)}}
        module['netnames']['out'] = {'bits': [2]}
        before = copy.deepcopy(module)
        summary = repair(module, pins, fanout=8)
        self.assertGreater(summary['buffer_count'], 0)
        new_buffers = {name: cell for name, cell in module['cells'].items()
                       if name not in before['cells']}
        roots = {cell['connections']['Z'][0]: cell['connections']['A'][0]
                 for cell in new_buffers.values()}

        def original_bit(bit):
            seen = set()
            while bit in roots:
                self.assertNotIn(bit, seen)
                seen.add(bit)
                bit = roots[bit]
            return bit

        self.assertEqual({name: [original_bit(b) for b in port['bits']]
                          for name, port in module['ports'].items()},
                         {name: port['bits'] for name, port in before['ports'].items()})
        for name, old in before['cells'].items():
            actual = module['cells'][name]
            for pin, bits in old['connections'].items():
                self.assertEqual([original_bit(bit) for bit in actual['connections'][pin]], bits)
        self.assertTrue(all(cell['type'] == 'BUF_X2' for cell in new_buffers.values()))
        # Repaired graphs are stable: rerunning must not grow another tree.
        self.assertEqual(repair(module, pins, fanout=8)['buffer_count'], 0)


    def test_capacitance_only_policy_preserves_legal_high_fanout(self):
        pins = {'BUF_X2': {
            'A': {'direction': 'input', 'capacitance': '0.002'},
            'Z': {'direction': 'output', 'function': 'A', 'max_capacitance': '0.12'}}}
        for count, expected_buffers in [(40, 0), (80, 2)]:
            with self.subTest(sink_count=count):
                cells = {'root': {'type': 'BUF_X2', 'parameters': {}, 'attributes': {},
                         'port_directions': {'A': 'input', 'Z': 'output'},
                         'connections': {'A': [1], 'Z': [2]}}}
                for index in range(count):
                    cells[f'sink_{index}'] = {
                        'type': 'BUF_X2', 'parameters': {}, 'attributes': {},
                        'port_directions': {'A': 'input', 'Z': 'output'},
                        'connections': {'A': [2], 'Z': [index + 3]}}
                module = {'cells': cells, 'ports': {'in': {'direction': 'input', 'bits': [1]}},
                          'netnames': {f'n{i}': {'bits': [i]} for i in range(1, count + 3)}}
                summary = repair(module, pins, fanout=0, headroom=1.0)
                self.assertEqual(summary['buffer_count'], expected_buffers)
                self.assertIsNone(summary['project_fanout_limit'])
                self.assertGreater(summary['maximum_cell_output_fanout'], 16)
                self.assertEqual(summary['static_load_audit'], 'passed')
                self.assertEqual(repair(module, pins, fanout=0, headroom=1.0)['buffer_count'], 0)


if __name__ == '__main__':
    unittest.main()
