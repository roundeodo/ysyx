#!/usr/bin/env python3
"""Check fanout repair by independently evaluating every new buffer connection."""
import copy
import unittest
from buffer_history_training import inspect, repair, TRIGGER_LOADS


def fixture(count):
    module = {'ports': {'a': {'direction': 'input', 'bits': [10]},
                        'b': {'direction': 'input', 'bits': [11]}},
              'cells': {}, 'netnames': {}}
    for bank in range(2):
        module['netnames'][f'u_core.u_branch_predictor.u_bht.g_counter_table.training_counter_{bank}_'] = {'bits': [10+bank]}
        for index in range(count):
            module['cells'][f'bank{bank}_cell{index}'] = {
                'type': 'DFF_X1', 'parameters': {}, 'attributes': {},
                'port_directions': {'D': 'input', 'CK': 'input', 'Q': 'output'},
                'connections': {'D': [10+bank], 'CK': [2], 'Q': [100+bank*count+index]}}
    return module


class BufferTests(unittest.TestCase):
    def test_truth_table_and_fanout(self):
        for count, expected in [(65, 10), (256, 32), (512, 96)]:
            with self.subTest(count=count):
                module = fixture(count)
                roots, loads = inspect(module)
                result = repair(module, roots, loads)
                self.assertEqual(result['buffer_count'], expected)
                for a, b in [(0, 0), (0, 1), (1, 0), (1, 1)]:
                    values = {10: a, 11: b}
                    pending = [cell for cell in module['cells'].values() if cell['type'] == 'BUF_X4']
                    while pending:
                        ready = [cell for cell in pending if cell['connections']['A'][0] in values]
                        self.assertTrue(ready, 'Undriven net or combinational loop')
                        for cell in ready:
                            values[cell['connections']['Z'][0]] = values[cell['connections']['A'][0]]
                            pending.remove(cell)
                    for bank, expected_value in enumerate([a, b]):
                        for index in range(count):
                            cell = module['cells'][f'bank{bank}_cell{index}']
                            self.assertEqual(values[cell['connections']['D'][0]], expected_value)
                            self.assertEqual(cell['connections']['CK'], [2])
                            self.assertEqual(cell['connections']['Q'], [100+bank*count+index])

    def test_small_tables_are_below_trigger(self):
        for count in [16, 32, 64]:
            module = fixture(count)
            _, loads = inspect(module)
            self.assertTrue(all(len(v) <= TRIGGER_LOADS for v in loads.values()))

    def test_reject_clock_load(self):
        module = fixture(128)
        module['cells']['bank0_cell0']['connections']['CK'] = [10]
        with self.assertRaises(AssertionError):
            repair(module, *inspect(module))

    def test_other_cells_and_ports_are_preserved(self):
        module = fixture(128)
        module['cells']['unrelated'] = {'type': 'INV_X1', 'parameters': {}, 'attributes': {},
            'port_directions': {'A': 'input', 'ZN': 'output'}, 'connections': {'A': [77], 'ZN': [78]}}
        ports = copy.deepcopy(module['ports']); other = copy.deepcopy(module['cells']['unrelated'])
        repair(module, *inspect(module))
        self.assertEqual(module['ports'], ports)
        self.assertEqual(module['cells']['unrelated'], other)


if __name__ == '__main__':
    unittest.main()
