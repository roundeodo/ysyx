#!/usr/bin/env python3
"""Check target encoding against full-address behavior and an existing predictor model."""
import random
import unittest
from model_target_storage import TargetTable, evaluate
from model_branch import evaluate as full_reference


class TargetModelTests(unittest.TestCase):
    def test_full_width_matches_existing_model(self):
        rng = random.Random(137)
        records = []
        for _ in range(4000):
            pc = 0x80000000 + 4 * rng.randrange(96)
            kind = (pc >> 2) & 3
            records.append((pc, kind, kind != 0 or bool(rng.randrange(2)),
                            (pc + 4 * rng.randrange(1, 64)) & 0xffffffff, kind == 1, kind == 3))
        for entries, ways in [(16, 2), (32, 2), (32, 4)]:
            reference = full_reference(records, len(records), {'btb': entries, 'ways': ways, 'bht': 16, 'ras': 4, 'policy': 'all'})
            result = evaluate(records, entries, [32] * ways)
            self.assertEqual(result['counts']['errors'], reference['counts']['errors'])

    def test_near_distance_does_not_mean_same_high_bits(self):
        table = TargetTable(16, [16, 16])
        self.assertFalse(table.update(0x8000fffc, 0x80010000, 1))
        self.assertIsNone(table.lookup(0x8000fffc))
        self.assertTrue(table.update(0x80001000, 0x8000f000, 1))
        self.assertEqual(table.lookup(0x80001000)[1], 0x8000f000)

    def test_incompatible_update_removes_old_target(self):
        table = TargetTable(16, [8, 8])
        self.assertTrue(table.update(0x80000100, 0x80000180, 2))
        self.assertFalse(table.update(0x80000100, 0x90000000, 2))
        self.assertIsNone(table.lookup(0x80000100))

    def test_wide_way_preserves_arbitrary_target(self):
        table = TargetTable(32, [8, 12, 16, 32])
        for target in [0x80000104, 0x80001234, 0x80012340, 0xf0000001]:
            self.assertTrue(table.update(0x80000100, target, 2))
            self.assertEqual(table.lookup(0x80000100)[1], target)
            self.assertEqual(sum(e is not None and e[0] == 0x80000100 for row in table.table for e in row), 1)


if __name__ == '__main__': unittest.main()
