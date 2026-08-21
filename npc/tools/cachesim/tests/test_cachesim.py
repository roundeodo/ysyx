#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CACHESIM_BINARY = Path(sys.argv[1]).resolve()
del sys.argv[1]


class CacheSimTest(unittest.TestCase):
    def run_trace(
        self,
        trace_lines,
        capacity=8,
        line_size=4,
        ways=1,
        refill_model="fixed",
        refill_beat_bytes=4,
    ):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as trace_file:
            trace_file.write("\n".join(trace_lines) + "\n")
            trace_file.flush()
            command = [
                str(CACHESIM_BINARY),
                "--trace",
                trace_file.name,
                "--capacity-bytes",
                str(capacity),
                "--line-bytes",
                str(line_size),
                "--ways",
                str(ways),
                "--refill-model",
                refill_model,
                "--refill-beat-bytes",
                str(refill_beat_bytes),
                "--miss-penalty-cycles",
                "10",
                "--output-format",
                "json",
            ]
            completed = subprocess.run(
                command, check=True, text=True, capture_output=True
            )
        return json.loads(completed.stdout)

    def test_conflict_miss_classification(self):
        result = self.run_trace(
            ["0x0", "0x4", "0x0", "0x8", "0x0"]
        )
        self.assertEqual(result["accesses"], 5)
        self.assertEqual(result["hits"], 1)
        self.assertEqual(result["misses"], 4)
        self.assertEqual(result["compulsory_misses"], 3)
        self.assertEqual(result["capacity_misses"], 0)
        self.assertEqual(result["conflict_misses"], 1)

    def test_capacity_miss_classification(self):
        result = self.run_trace(
            ["0x0", "0x4", "0x8", "0x0"], capacity=8, line_size=4, ways=2
        )
        self.assertEqual(result["misses"], 4)
        self.assertEqual(result["compulsory_misses"], 3)
        self.assertEqual(result["capacity_misses"], 1)
        self.assertEqual(result["conflict_misses"], 0)

    def test_nemu_and_npc_text_formats(self):
        result = self.run_trace(
            [
                "physical memory area [0x80000000, 0x81ffffff]",
                "0x80000000: 00 00 05 13  addi a0, zero, 0",
                "itrace: 0x80000004: 00000013  nop",
            ],
            capacity=16,
            line_size=4,
            ways=1,
        )
        self.assertEqual(result["accesses"], 2)
        self.assertEqual(result["ignored_nonempty_lines"], 1)

    def test_independent_transactions_repeat_all_read_phases(self):
        result = self.run_trace(
            ["0x0", "0x1c"],
            capacity=16,
            line_size=16,
            ways=1,
            refill_model="independent",
        )
        self.assertEqual(result["misses"], 2)
        self.assertEqual(result["refill_beats_per_line"], 4)
        self.assertEqual(result["average_critical_beat_position"], 2.5)
        self.assertEqual(
            result["average_critical_response_penalty_cycles"], 10.0
        )
        self.assertEqual(result["average_complete_refill_penalty_cycles"], 16.0)
        self.assertEqual(result["critical_tmt_cycles"], 20.0)
        self.assertEqual(result["refill_occupancy_cycles"], 32.0)
        self.assertEqual(result["read_transactions"], 8)

    def test_incrementing_burst_pays_setup_once(self):
        result = self.run_trace(
            ["0x0", "0x1c"],
            capacity=16,
            line_size=16,
            ways=1,
            refill_model="burst",
        )
        self.assertEqual(result["misses"], 2)
        self.assertEqual(
            result["average_critical_response_penalty_cycles"], 5.5
        )
        self.assertEqual(result["average_complete_refill_penalty_cycles"], 7.0)
        self.assertEqual(result["critical_tmt_cycles"], 11.0)
        self.assertEqual(result["refill_occupancy_cycles"], 14.0)
        self.assertEqual(result["read_transactions"], 2)


if __name__ == "__main__":
    unittest.main()
