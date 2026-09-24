#!/usr/bin/env python3
"""Estimates cannot replace STA measurements or change the qualified grid point."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from sta_report import qualify_grid


class QualificationTest(unittest.TestCase):
    def check_curve(self, pass_points, estimate, cached=(), hold_fault=None):
        results, measured = {}, set()

        def measure(mhz):
            self.assertIn(mhz, range(200, 801, 20))
            measured.add(mhz)
            passed = mhz in pass_points
            results[str(mhz)] = {
                'passed': passed,
                'groups': {
                    'data_max': {'slack_ns': 1 if passed else -1, 'fmax_mhz': estimate},
                    'gating_max': {'slack_ns': 1},
                    'data_min': {'slack_ns': -1 if mhz == hold_fault else 1},
                    'gating_min': {'slack_ns': 1},
                },
            }
            return passed

        for mhz in cached:
            measure(mhz)
        chosen = qualify_grid(measure, results)
        self.assertEqual(chosen, max(pass_points, default=None))
        if chosen is not None:
            self.assertIn(chosen, measured)
            self.assertTrue(results[str(chosen)]['passed'])
            if chosen < 800:
                self.assertIn(chosen + 20, measured)
                self.assertFalse(results[str(chosen + 20)]['passed'])

    def test_all_boundaries_with_inaccurate_estimates(self):
        for limit in range(180, 801, 20):
            for estimate in [None, 100, 790, 2000, float('nan'), float('inf'), limit + 7.5]:
                with self.subTest(limit=limit, estimate=estimate):
                    self.check_curve(set(range(200, limit + 1, 20)), estimate)

    def test_period_scaled_input_delay(self):
        # A register/input path has slope 1 or 0.8 in the clock period. The
        # reported Fmax assumes a fixed path delay, so it changes after retiming.
        for limit in range(200, 800, 20):
            for slope in [0.5, 0.8, 1.0]:
                for cached in [False, True]:
                    results = {}
                    boundary_period = 1000 / (limit + 7)

                    def measure(mhz):
                        period = 1000 / mhz
                        slack = slope * (period - boundary_period)
                        results[str(mhz)] = {'passed': slack >= 0, 'groups': {
                            'data_max': {'slack_ns': slack, 'fmax_mhz': 1000 / (period - slack)},
                            'gating_max': {'slack_ns': 1},
                            'data_min': {'slack_ns': 1}, 'gating_min': {'slack_ns': 1}}}
                        return slack >= 0

                    if cached:
                        measure(800)
                        measure(min(800, limit + 20))
                    chosen = qualify_grid(measure, results)
                    self.assertEqual(chosen, limit)
                    self.assertTrue(results[str(limit)]['passed'])
                    self.assertFalse(results[str(limit + 20)]['passed'])

    def test_cached_nonmonotone_results(self):
        self.check_curve({200, 220, 600, 720}, 401, cached=[260, 600])

    def test_cached_hold_failure(self):
        self.check_curve({200, 220, 600, 720}, 401, cached=[260], hold_fault=260)


if __name__ == '__main__':
    unittest.main()
