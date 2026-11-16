#!/usr/bin/env python3
"""Check the bound against exhaustive replacement, and run compression independently."""
from functools import lru_cache
import itertools
from pathlib import Path
import random
import struct
import tempfile
import unittest

from scan_icache_capacity import POLICIES, line_runs, read_program_counters, simulate


def exhaustive_misses(lines, set_count, ways):
    @lru_cache(None)
    def visit(position, resident):
        if position == len(lines):
            return 0
        line = lines[position]
        if line in resident:
            return visit(position + 1, resident)
        occupants = [item for item in resident if item % set_count == line % set_count]
        if len(occupants) < ways:
            return 1 + visit(position + 1, tuple(sorted((*resident, line))))
        return 1 + min(visit(position + 1, tuple(sorted(
            [item for item in resident if item != victim] + [line]))) for victim in occupants)
    return visit(0, ())


class ModelTests(unittest.TestCase):
    def test_opt_matches_all_possible_victims(self):
        for trace in itertools.product(range(3), repeat=7):
            for sets in (1, 2):
                expected = exhaustive_misses(trace, sets, 2)
                actual = simulate(trace, [1] * len(trace), sets * 2 * 16, 16, 2, "opt")
                self.assertEqual(actual, expected, trace)

    def test_compression_keeps_hit_promotion(self):
        rng = random.Random(615)
        for _ in range(40):
            lines = [rng.randrange(12) for _ in range(200)]
            compressed, counts = line_runs([line * 16 for line in lines], 16)
            for policy in POLICIES:
                self.assertEqual(simulate(lines, [1] * len(lines), 64, 16, 2, policy),
                                 simulate(compressed, counts, 64, 16, 2, policy))

    def test_direct_mapped_has_no_replacement_choice(self):
        lines = [0, 2, 0, 2, 1, 3, 1, 1]
        for policy in POLICIES:
            self.assertEqual(simulate(lines, [1] * len(lines), 32, 16, 1, policy), 7)

    def test_illegal_geometry_rejected(self):
        with self.assertRaises(ValueError):
            simulate([0], [1], 320, 16, 4, "fifo")

    def test_binary_reader_validates_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.bin"
            header = struct.pack("<8sIIQQ", b"NPCPCTR1", 1, 4, 5, 2)
            path.write_bytes(header + struct.pack("<QIi", 100, 3, 4) + struct.pack("<QIi", 96, 2, -4))
            self.assertEqual(list(read_program_counters(path)), [100, 104, 108, 96, 92])
            path.write_bytes(path.read_bytes()[:-1])
            with self.assertRaises(ValueError):
                read_program_counters(path)


if __name__ == "__main__":
    unittest.main()
