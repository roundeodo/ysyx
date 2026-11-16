#!/usr/bin/env python3

import csv
import sys
import tempfile
import unittest
from pathlib import Path


NPC_DIR = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(NPC_DIR / "scripts"))
sys.path.insert(0, str(NPC_DIR / "tools" / "cachesim"))

from calibrate_icache_penalty import parse_calibration_output, parse_line_sizes
from explore import parse_penalty_calibration


SAMPLE_OUTPUT = """
I-cache AMAT counters:
  lookups / cacheable hits / cacheable misses : 1000 / 990 / 10
  average hit response latency                : 2.000 cycles
  average miss critical response latency      : 33.250 cycles
  average miss penalty                        : 31.250 cycles
  average complete refill latency             : 48.500 cycles

MicroBench PMU measurement window:
  cycles               = 10000
  retired instructions = 2500
  IPC                  = 0.250000
"""


class CalibrationTest(unittest.TestCase):
    def test_line_size_validation(self):
        self.assertEqual(parse_line_sizes("8,16,32,64"), [8, 16, 32, 64])
        with self.assertRaises(ValueError):
            parse_line_sizes("16,16")
        with self.assertRaises(ValueError):
            parse_line_sizes("128")

    def test_parse_rtl_counters(self):
        result = parse_calibration_output(
            SAMPLE_OUTPUT,
            32,
            64,
            1,
            "test",
            "riscv32-ysyxsoc-psram",
        )
        self.assertEqual(result.cache_miss_count, 10)
        self.assertEqual(result.cache_capacity_bytes, 64)
        self.assertEqual(result.cache_way_count, 1)
        self.assertEqual(result.benchmark_arch, "riscv32-ysyxsoc-psram")
        self.assertEqual(result.average_miss_penalty_cycles, 31.25)
        self.assertEqual(result.average_complete_refill_latency_cycles, 48.5)
        self.assertAlmostEqual(result.exact_amat_cycles, 2.3125)
        self.assertAlmostEqual(result.measurement_window_ipc, 0.25)

    def test_explorer_reads_calibration_csv(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            csv_path = Path(temporary_directory) / "calibration.csv"
            with csv_path.open("w", newline="", encoding="utf-8") as output_file:
                writer = csv.DictWriter(
                    output_file,
                    fieldnames=[
                        "line_bytes",
                        "average_miss_penalty_cycles",
                        "average_complete_refill_latency_cycles",
                    ],
                )
                writer.writeheader()
                writer.writerow(
                    {
                        "line_bytes": 32,
                        "average_miss_penalty_cycles": 31.25,
                        "average_complete_refill_latency_cycles": 48.5,
                    }
                )

            critical, complete = parse_penalty_calibration(csv_path)
            self.assertEqual(critical, {32: 31.25})
            self.assertEqual(complete, {32: 48.5})


if __name__ == "__main__":
    unittest.main()
