#!/usr/bin/env python3
"""Architectural identity and matched-window accounting checks."""
import copy
import unittest
from pathlib import Path

from qualify_branch_runs import check_architecture, check_command
from select_branch import geometric, ratios


class MeasurementTests(unittest.TestCase):
    def setUp(self):
        self.baseline = {'results': [
            {'case': {'name': name}, 'seconds': seconds,
             'result': {'retired': 20, 'all_retired': 30, 'digest': 123, 'checksum': 456, 'cycles': cycles}}
            for name, seconds, cycles in [('short', .1, 100), ('long', 1., 1000)]]}

    def test_cycle_changes_preserve_architecture(self):
        measured = copy.deepcopy(self.baseline)
        measured['results'][0]['result']['cycles'] = 75
        check_architecture(self.baseline, measured)

    def test_store_checksum_or_retirement_difference_is_rejected(self):
        for field in ['retired', 'all_retired', 'digest', 'checksum']:
            measured = copy.deepcopy(self.baseline)
            measured['results'][0]['result'][field] += 1
            with self.assertRaises(AssertionError):
                check_architecture(self.baseline, measured)

    def test_missing_and_duplicate_cases_are_rejected(self):
        for rows in [self.baseline['results'][:1], [self.baseline['results'][0]] * 2]:
            with self.assertRaises(AssertionError):
                check_architecture(self.baseline, {'results': rows})

    def test_comparison_uses_identity_and_equal_weight_ratios(self):
        measured = copy.deepcopy(self.baseline)
        measured['results'][0]['seconds'] *= .5
        measured['results'][1]['seconds'] *= 2
        measured['results'].reverse()
        result = ratios(self.baseline, measured)
        self.assertEqual(result, {'short': .5, 'long': 2})
        self.assertEqual(geometric(list(result.values())), 1.)

    def test_simulator_arguments_match_reported_clock_and_window(self):
        case = {'begin_pc': 0x80000000, 'end_pc': 0x80000008, 'expected': 0xab}
        binary, image = Path('/tmp/test-simulator'), Path('/tmp/test-image.hex')
        command = [str(binary), f'+image={image}', '+begin_pc=80000000', '+end_pc=80000008',
                   '+expected=ab', '+cpu_mhz=700', '+latency_ns=100', '+beat_ns=10',
                   '+seed=97531', '+memory_mode=physical', '+random_stalls=0', '+observer=1']
        check = lambda args: check_command(args, binary, image, case, 700, 100, 10, False, True)
        check(command)
        for original, altered in [('+cpu_mhz=700', '+cpu_mhz=720'),
                                  ('+end_pc=80000008', '+end_pc=8000000c'),
                                  ('+memory_mode=physical', '+memory_mode=cycle'),
                                  (f'+image={image}', '+image=/tmp/different.hex')]:
            with self.assertRaises(AssertionError):
                check([altered if arg == original else arg for arg in command])
        with self.assertRaises(AssertionError):
            check(command + ['+cpu_mhz=700'])


if __name__ == '__main__':
    unittest.main()
