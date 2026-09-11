#!/usr/bin/env python3
"""Reject plausible-looking IPC reports with wrong timer boundaries or images."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('measurement', Path(__file__).resolve().parents[2] / 'scripts/run_microbench_perf.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MeasurementTests(unittest.TestCase):
    def setUp(self):
        self.layout = {'init_load_pc': 100, 'uptime_load_pc': 200,
                       'main_timer_return_pcs': [1000, 2000, 3000, 4000]}
        contexts = [0, 1000] + [2000, 3000] * 10 + [4000]
        self.events = [{'type': 'configuration', 'schema': 1, 'cpu_hz': 820000000,
                        'timer_hz': 1000000, 'boundary': 'pre_rising_edge'}]
        for i, context in enumerate(contexts):
            self.events.append({'type': 'timer_sample', 'cycle': 100 + i * 8200,
                                'retired': 50 + i * 100, 'ticks': i * 10,
                                'load_pc': 100 if i == 0 else 200, 'return_pc': context,
                                'interrupts': 0, 'load_commit_cycle': 107 + i * 8200,
                                'successful_load': True})
        self.events.append({'type': 'finish', 'valid': True, 'good_exit': True,
                            'cycles': 200000, 'retired': 2400, 'interrupts': 0, 'clint_writes': 0})
        self.log = 'Passed.\n' * 10 + 'MicroBench PASS\nScored time: 0.100 ms\nTotal  time: 0.210 ms\nHIT GOOD TRAP\n'

    def test_valid_delayed_retirement(self):
        report = m.analyze(self.events, self.log, self.layout, 820)
        self.assertEqual(report['scored']['cycles'], 82000)
        self.assertEqual(report['scored']['retired_instructions'], 1000)
        self.assertAlmostEqual(report['scored']['ipc'], 1000 / 82000)
        self.assertEqual(report['total']['timer_seconds'], .000210)

    def test_reject_invalid_evidence(self):
        changes = [lambda e: e.pop(3),
                   lambda e: e[4].update(return_pc=4000),
                   lambda e: e[4].update(load_pc=999),
                   lambda e: e[4].update(successful_load=False),
                   lambda e: e[4].update(ticks=e[4]['ticks'] + 1),
                   lambda e: e[4].update(cycle=e[3]['cycle']),
                   lambda e: e[-1].update(valid=False),
                   lambda e: e[-1].update(good_exit=False),
                   lambda e: e[-1].update(clint_writes=1),
                   lambda e: e[0].update(cpu_hz=100000000)]
        for change in changes:
            with self.subTest(change=change):
                events = copy.deepcopy(self.events)
                change(events)
                with self.assertRaises(ValueError):
                    m.analyze(events, self.log, self.layout, 820)

    def test_native_time_must_match(self):
        with self.assertRaises(ValueError):
            m.analyze(self.events, self.log.replace('0.100', '0.101'), self.layout, 820)

    def test_sub_tick_quantization_allowed(self):
        self.events[4]['cycle'] += 100
        self.events[4]['load_commit_cycle'] += 100
        m.analyze(self.events, self.log, self.layout, 820)

    def test_ipc_is_weighted_by_cycles(self):
        self.events[4]['retired'] += 50
        report = m.analyze(self.events, self.log, self.layout, 820)
        self.assertEqual(report['scored']['retired_instructions'], 1050)
        self.assertEqual(report['scored']['ipc'], 1050 / 82000)


if __name__ == '__main__':
    unittest.main()
