#!/usr/bin/env python3
"""Check family weighting, physical clock conversion, and architectural identity."""
import copy
import unittest
from finalize_branch_followup import compare


def row(family, cycles):
    return {'case': {'kind': family},
            'result': {'cycles': cycles, 'retired': 10, 'all_retired': 12,
                       'digest': 123, 'checksum': 456},
            'counters': {'i_beats': 8, 'd_beats': 6}}


class FollowupMeasurementTests(unittest.TestCase):
    def test_each_family_has_equal_weight_even_with_unequal_input_counts(self):
        reference = {'a1': row('a', 100), 'a2': row('a', 100), 'b1': row('b', 100)}
        candidate = {'a2': row('a', 200), 'b1': row('b', 25), 'a1': row('a', 200)}
        result = compare(candidate, reference, 660, 660, 100, 100)
        self.assertAlmostEqual(result['time_ratio_gm'], 0.5 ** 0.5)
        self.assertEqual(result['max_input_time_ratio'], 2)

    def test_remeasured_cycles_use_each_configurations_actual_legal_frequency(self):
        result = compare({'a': row('a', 90)}, {'a': row('a', 100)}, 660, 720, 110, 100)
        self.assertAlmostEqual(result['time_ratio_gm'], 90 / 660 / (100 / 720))
        self.assertAlmostEqual(result['adp_ratio'], 1.1 * 90 / 660 / (100 / 720))
        self.assertAlmostEqual(result['cases']['a']['seconds'], 90 / 660e6)
        self.assertEqual(result['cases']['a']['d_transfer_cycles'], 6)

    def test_changed_retirement_or_output_is_not_a_performance_result(self):
        reference = {'a': row('a', 100)}
        for field in ['retired', 'all_retired', 'digest', 'checksum']:
            candidate = copy.deepcopy(reference)
            candidate['a']['result'][field] += 1
            with self.assertRaises(AssertionError):
                compare(candidate, reference, 660, 660, 100, 100)

    def test_missing_case_is_rejected(self):
        with self.assertRaises(AssertionError):
            compare({}, {'a': row('a', 100)}, 660, 660, 100, 100)


if __name__ == '__main__':
    unittest.main()
