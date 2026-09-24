#!/usr/bin/env python3
"""Small independent examples for branch model semantics, not CPU timing tests."""
import unittest

from model_branch import decode, evaluate


class BranchModelTests(unittest.TestCase):
    base = {'bht': 16, 'btb': 16, 'ways': 2, 'ras': 4, 'policy': 'all'}

    def test_cold_always_taken(self):
        records = [(0x100, 0, True, 0x120, False, False)] * 8
        result = evaluate(records, 32, self.base)
        self.assertEqual(result['counts']['errors'], 1)
        self.assertEqual(result['counts']['allocations'], 1)

    def test_never_taken_admission(self):
        records = [(0x100 + i * 4, 0, False, 0x500, False, False) for i in range(20)]
        baseline = evaluate(records, 20, self.base)
        filtered = evaluate(records, 20, dict(self.base, policy='taken'))
        self.assertEqual(baseline['counts']['not_taken_allocations'], 20)
        self.assertEqual(filtered['counts']['suppressed_allocations'], 20)
        self.assertEqual(filtered['counts'].get('errors', 0), 0)

    def test_target_updates(self):
        records = [(0x100, 2, True, target, False, False) for target in [0x200, 0x200, 0x300, 0x300]]
        result = evaluate(records, 4, self.base)
        self.assertEqual(result['counts']['errors'], 2)
        self.assertEqual(result['counts']['target_errors'], 1)

    def test_return_requires_btb_identity(self):
        records = [(0x100, 1, True, 0x200, True, False),
                   (0x208, 3, True, 0x104, False, True)] * 2
        result = evaluate(records, 4, self.base)
        self.assertEqual(result['counts']['errors'], 2)

    def test_x1_and_x5_decode(self):
        self.assertEqual(decode(0x100, 0x00008067, 0x200)[1], 3)
        self.assertEqual(decode(0x100, 0x00028067, 0x200)[1], 3)
        self.assertEqual(decode(0x100, 0x00050067, 0x200)[1], 2)
        self.assertIsNone(decode(0x100, 0x00000013, 0x104))

    def test_rrip_retains_the_reused_target(self):
        # All PCs map to one two-way set. Reuse A before inserting C;
        # a round-robin replacement discards A, RRIP discards unused B.
        records = [(pc, 1, True, pc + 0x100, False, False)
                   for pc in [0x100, 0x120, 0x100, 0x140, 0x100]]
        round_robin = evaluate(records, 5, dict(self.base, policy='taken'))
        rrip = evaluate(records, 5, dict(self.base, policy='taken_rrip'))
        self.assertEqual(round_robin['counts']['errors'], 4)
        self.assertEqual(rrip['counts']['errors'], 3)

    def test_not_taken_lru_update_changes_victim(self):
        # Warm A's direction counter, then exercise the distinction between
        # retaining a looked-up branch and retaining a used taken target.
        sequence = [(0x100, True), (0x100, True), (0x120, True),
                    (0x100, False), (0x140, True), (0x100, True)]
        records = [(pc, 0 if pc == 0x100 else 1, taken, pc + 0x100, False, False)
                   for pc, taken in sequence]
        taken_only = evaluate(records, 6, dict(self.base, policy='taken_lru'))
        all_hits = evaluate(records, 6, dict(self.base, policy='allhit_lru'))
        self.assertEqual(taken_only['counts']['errors'], all_hits['counts']['errors'] + 1)

    def test_global_history_correlates_repeated_pattern(self):
        records = [(0x100, 0, taken, 0x120, False, False)
                   for taken in [True, True, False, False] * 40]
        local = evaluate(records, 160, self.base)
        history = evaluate(records, 160, dict(self.base, history=2))
        self.assertLess(history['counts']['errors'], 10)
        self.assertGreater(local['counts']['errors'], 100)


if __name__ == '__main__':
    unittest.main()
