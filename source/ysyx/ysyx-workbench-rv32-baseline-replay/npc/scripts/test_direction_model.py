#!/usr/bin/env python3
"""Directed semantics for the exploratory direction models."""
import unittest

from model_branch import evaluate
from model_direction import BiMode, CounterTable, LoopTable, Unaliased, working_sets


class DirectionTests(unittest.TestCase):
    target = dict(bht=64, btb=32, ways=2, ras=4, policy='taken')

    def test_counter_adapter_matches_original(self):
        records = [(0x100 + (i % 9) * 4, 0, i % 5 != 0, 0x200, False, False) for i in range(700)]
        original = evaluate(records, 700, self.target)
        adapter = evaluate(records, 700, self.target, CounterTable(64))
        self.assertEqual(original, adapter)

    def test_bimode_preserves_successful_exception(self):
        predictor = BiMode(64, 0)
        predictor.tables[0][0] = 2
        self.assertTrue(predictor.predict(0x100, 0x200))
        predictor.update(0x100, 0x200, True)
        self.assertEqual(predictor.choice[0], 1)
        self.assertEqual(predictor.tables[0][0], 3)
        self.assertEqual(predictor.tables[1][0], 2)

    def test_bimode_changes_bad_choice(self):
        predictor = BiMode(64, 0)
        self.assertFalse(predictor.predict(0x100, 0x200))
        predictor.update(0x100, 0x200, True)
        self.assertEqual(predictor.choice[0], 2)
        self.assertEqual(predictor.tables[1][0], 2)

    def test_high_confidence_waits_for_second_taken(self):
        predictor = CounterTable(16, threshold=3)
        self.assertFalse(predictor.predict(0x100, 0x200))
        predictor.update(0x100, 0x200, True)
        self.assertFalse(predictor.predict(0x100, 0x200))
        predictor.update(0x100, 0x200, True)
        self.assertTrue(predictor.predict(0x100, 0x200))

    def test_short_history_alignment(self):
        lower = CounterTable(64, history_bits=4)
        upper = CounterTable(64, history_bits=4, history_shift=2)
        for taken in [True, True]:
            lower.update(0x104, 0x200, taken)
            upper.update(0x104, 0x200, taken)
        self.assertEqual(lower.index(0x104), 2)
        self.assertEqual(upper.index(0x104), 13)
        self.assertEqual(lower.state_bits(), upper.state_bits())

    def test_loop_learns_exit_and_recovers_trip_change(self):
        predictor = LoopTable(4)
        for taken in [True, True, True, False] * 4:
            predictor.predict(0x100, 0x80)
            predictor.update(0x100, 0x80, taken)
        for expected in [True, True, True, False]:
            self.assertEqual(predictor.predict(0x100, 0x80), expected)
            predictor.update(0x100, 0x80, expected)
        for taken in [True, True, True, True, False]:
            predictor.predict(0x100, 0x80)
            predictor.update(0x100, 0x80, taken)
        self.assertEqual(predictor.find(0x100)['confidence'], 0)
        self.assertEqual(predictor.find(0x100)['trip'], 4)

    def test_loop_overflow_does_not_learn_wrapped_trip(self):
        predictor = LoopTable(4)
        for taken in [True] * 300 + [False]:
            predictor.predict(0x100, 0x80)
            predictor.update(0x100, 0x80, taken)
        entry = predictor.find(0x100)
        self.assertEqual((entry['confidence'], entry['current'], entry['trip']), (0, 0, 0))
        self.assertFalse(entry['overflow'])

    def test_unaliased_separates_opposing_pc_biases(self):
        records = [(pc, 0, taken, 0x800, False, False)
                   for _ in range(80) for pc, taken in [(0x100, True), (0x200, False)]]
        shared = evaluate(records, 160, self.target, CounterTable(64))
        unique = evaluate(records, 160, self.target, Unaliased())
        self.assertGreater(shared['counts']['errors'], unique['counts']['errors'])

    def test_working_set_is_descriptive_not_online_prediction(self):
        records = [(0x100, 0, taken, 0x80, False, False) for taken in [True, False] * 20]
        rows = working_sets(records)
        self.assertEqual(rows['0']['working_set_95'], 1)
        self.assertEqual(rows['0']['retrospective_bias'], .5)
        self.assertEqual(rows['4']['retrospective_bias'], 1)


if __name__ == '__main__':
    unittest.main()
