#!/usr/bin/env python3

import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CACHESIM_BINARY = Path(sys.argv[1]).resolve()
del sys.argv[1]


class CacheSimTest(unittest.TestCase):
    def run_binary_data_trace(
        self,
        data_access_runs,
        capacity=8,
        line_size=4,
        ways=1,
        dirty_writeback_penalty=0,
    ):
        access_count = sum(run[1] for run in data_access_runs)
        with tempfile.NamedTemporaryFile("wb") as trace_file:
            trace_file.write(
                struct.pack(
                    "<8sIIQQ",
                    b"NPCDCTR1",
                    1,
                    4,
                    access_count,
                    len(data_access_runs),
                )
            )
            for first_address, run_access_count, stride, size, is_write in data_access_runs:
                trace_file.write(
                    struct.pack(
                        "<QIhBB",
                        first_address,
                        run_access_count,
                        stride,
                        size,
                        1 if is_write else 0,
                    )
                )
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
                "--critical-response-penalty-cycles",
                "10",
                "--complete-refill-penalty-cycles",
                "10",
                "--dirty-writeback-penalty-cycles",
                str(dirty_writeback_penalty),
                "--output-format",
                "json",
            ]
            completed = subprocess.run(
                command, check=True, text=True, capture_output=True
            )
        return json.loads(completed.stdout)

    def run_binary_trace(
        self,
        program_counter_runs,
        capacity=8,
        line_size=4,
        ways=1,
    ):
        instruction_count = sum(run[1] for run in program_counter_runs)
        with tempfile.NamedTemporaryFile("wb") as trace_file:
            trace_file.write(
                struct.pack(
                    "<8sIIQQ",
                    b"NPCPCTR1",
                    1,
                    4,
                    instruction_count,
                    len(program_counter_runs),
                )
            )
            for first_program_counter, run_instruction_count, stride in program_counter_runs:
                trace_file.write(
                    struct.pack(
                        "<QIi",
                        first_program_counter,
                        run_instruction_count,
                        stride,
                    )
                )
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
                "--critical-response-penalty-cycles",
                "10",
                "--complete-refill-penalty-cycles",
                "10",
                "--output-format",
                "json",
            ]
            completed = subprocess.run(
                command, check=True, text=True, capture_output=True
            )
        return json.loads(completed.stdout)

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
                "--critical-response-penalty-cycles",
                "10",
                "--complete-refill-penalty-cycles",
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

    def test_binary_run_trace_matches_program_counter_sequence(self):
        result = self.run_binary_trace(
            [(0x0, 3, 4), (0x0, 1, 0)],
            capacity=8,
            line_size=4,
            ways=2,
        )
        self.assertEqual(result["accesses"], 4)
        self.assertEqual(result["misses"], 4)
        self.assertEqual(result["compulsory_misses"], 3)
        self.assertEqual(result["capacity_misses"], 1)
        self.assertEqual(result["conflict_misses"], 0)

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
        self.assertEqual(result["blocking_tmt_cycles"], 32.0)
        self.assertEqual(result["refill_occupancy_cycles"], 32.0)
        self.assertEqual(result["blocking_amat_cycles"], 18.0)
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
        self.assertEqual(result["blocking_tmt_cycles"], 14.0)
        self.assertEqual(result["refill_occupancy_cycles"], 14.0)
        self.assertEqual(result["blocking_amat_cycles"], 9.0)
        self.assertEqual(result["read_transactions"], 2)

    def test_data_trace_tracks_load_store_and_dirty_eviction(self):
        result = self.run_binary_data_trace(
            [
                (0x0, 1, 0, 4, True),
                (0x8, 1, 0, 4, True),
                (0x0, 1, 0, 4, False),
            ],
            dirty_writeback_penalty=7,
        )
        self.assertEqual(result["trace_kind"], "data")
        self.assertEqual(result["architectural_accesses"], 3)
        self.assertEqual(result["loads"], 1)
        self.assertEqual(result["stores"], 2)
        self.assertEqual(result["accesses"], 3)
        self.assertEqual(result["misses"], 3)
        self.assertEqual(result["dirty_evictions"], 2)
        self.assertEqual(result["dirty_writeback_cycles"], 14.0)
        self.assertEqual(result["blocking_tmt_cycles"], 44.0)

    def test_cross_line_data_access_updates_each_touched_line(self):
        result = self.run_binary_data_trace([(0x3, 1, 0, 2, False)])
        self.assertEqual(result["architectural_accesses"], 1)
        self.assertEqual(result["accesses"], 2)
        self.assertEqual(result["misses"], 2)


if __name__ == "__main__":
    unittest.main()
