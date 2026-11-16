#!/usr/bin/env python3
"""Verify ordered timer samples when bypass allows overlap with old retirement."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class ObserverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.output = Path(cls.directory.name)
        npc = Path(__file__).resolve().parents[2]
        cls.binary = cls.output / 'observer-test'
        subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                        '-I' + str(npc / 'include'), str(npc / 'csrc/perf_observer.cpp'),
                        str(Path(__file__).with_name('perf_observer_tb.cpp')),
                        '-o', str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_case(self, mode):
        output = self.output / f'case-{mode}.jsonl'
        subprocess.run([str(self.binary), str(output), str(mode)], check=True)
        return [json.loads(row) for row in output.read_text().splitlines()]

    def test_overlapping_reads_with_same_pc(self):
        events = self.run_case(0)
        self.assertTrue(events[-1]['valid'])
        self.assertEqual([e['cycle'] for e in events[1:-1]], [100, 102])
        self.assertEqual([e['return_pc'] for e in events[1:-1]], [0x2000, 0x3000])
        self.assertEqual([e['load_commit_cycle'] for e in events[1:-1]], [104, 108])

    def test_fault_rejects_measurement(self):
        self.assertFalse(self.run_case(1)[-1]['valid'])

    def test_unretired_sample_rejects_measurement(self):
        self.assertFalse(self.run_case(2)[-1]['valid'])


if __name__ == '__main__':
    unittest.main()
