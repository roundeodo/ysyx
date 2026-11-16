#!/usr/bin/env python3
"""Guard against accepting a positive setup result with other failed checks."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from check_sta_acceptance import clock_coverage_report, electrical_report, timing_report


class AcceptanceTests(unittest.TestCase):
    def test_reset_removal_rejects_positive_setup(self):
        report = '''
| result | core_clock | max | 1.0 | 1.03 | 0 | 0.030 | 715 |
| reset:RN | core_clock | min | 0.286 | 0.306 | 0 | -0.021 | NA |
| enable:E | **clock_gating_default** | max | 1.0 | 1.1 | 0 | 0.100 | NA |
| enable:E | **clock_gating_default** | min | 0.1 | 0.0 | 0 | 0.100 | NA |
| core_clock | max | 0.000 |
| core_clock | min | -22.786 |
| slack (VIOLATED) | -0.021 |
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'core.rpt'
            path.write_text(report)
            self.assertFalse(timing_report(path)['passed'])
            path.write_text(report.replace('-0.021', '0.021').replace('-22.786', '0.000')
                            .replace('VIOLATED', 'MET'))
            self.assertTrue(timing_report(path)['passed'])

    def test_tns_in_first_clock_group_is_not_overwritten(self):
        report = """
| result | core_clock | max | 1.0 | 1.03 | 0 | 0.030 | 715 |
| result | core_clock | min | 0.1 | 0.0 | 0 | 0.100 | NA |
| enable | **clock_gating_default** | max | 1.0 | 1.1 | 0 | 0.100 | NA |
| enable | **clock_gating_default** | min | 0.1 | 0.0 | 0 | 0.100 | NA |
| core_clock | max | -0.010 |
| core_clock | min | 0.000 |
| buffered_core_clock | max | 0.000 |
| buffered_core_clock | min | 0.000 |
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'core.rpt'
            path.write_text(report)
            result = timing_report(path)
            self.assertFalse(result['passed'])
            self.assertEqual(result['tns_ns']['max'], -0.010)

    def test_missing_capture_clock_rejects_successful_engine_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'sta.log'
            path.write_text('E end vertex result_ff:D has no clock data.\n'
                            'E end vertex result_ff:D has no clock data.\n'
                            'The timing engine run success.\n')
            report = clock_coverage_report(path)
            self.assertFalse(report['passed'])
            self.assertEqual(report['missing_clock_diagnostics'], 2)
            self.assertEqual(report['missing_clock_endpoints'], ['result_ff:D'])
            path.write_text('The timing engine run success.\n')
            self.assertTrue(clock_coverage_report(path)['passed'])

    def test_electrical_negative_rounded_zero_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'core.cap'
            for slack, passed in [('0.020r/0.021f', True),
                                  ('-0.001r/0.021f', False),
                                  ('-0.000r/0.021f', False)]:
                path.write_text(f'| driver:Q | 0.060 | 0.040 | {slack} | DFF_X1/Q | R |\n')
                self.assertEqual(electrical_report(path)['passed'], passed)
            path.write_text('No electrical report generated\n')
            with self.assertRaises(ValueError):
                electrical_report(path)


if __name__ == '__main__':
    unittest.main()
