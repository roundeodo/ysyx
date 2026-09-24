#!/usr/bin/env python3
"""Recovery must treat all history choices equally; branch events are not cycles."""
import random
import unittest
from unittest.mock import patch
import model_history_timing as timing
from model_history import SmallTage


class AlwaysWrong:
    def __init__(self, entries):
        self.history=0
    def lookup(self, pc, history):
        return {'taken':False,'history':history}
    def train(self, query, actual):
        self.history=((self.history<<1)|actual)&65535


class RecoveryTests(unittest.TestCase):
    def test_every_mode_replays_younger_lookups(self):
        records=[(0x100+4*i,0,True,0x80,0,0) for i in range(4)]
        with patch.object(timing,'SmallTage',AlwaysWrong):
            for mode in ['resolved','oracle-prefix','speculative']:
                counts=timing.evaluate(records,16,4,mode)
                # Independent schedule: query 4, then replay 3, 2, 1 entries.
                self.assertEqual(counts['resolved'],4)
                self.assertEqual(counts['errors'],4)
                self.assertEqual(counts['queries'],10)
                self.assertEqual(counts['replayed_queries'],6)

    def test_one_event_delay_equals_immediate_training(self):
        rng=random.Random(551)
        records=[(0x100+4*rng.randrange(16),0,bool(rng.getrandbits(1)),0x80,0,0) for _ in range(1200)]
        model=SmallTage(16);errors=0
        for pc,_,actual,target,_,_ in records:
            errors+=model.predict(pc,target)!=actual
            model.update(pc,target,actual)
        for mode in ['resolved','oracle-prefix','speculative']:
            counts=timing.evaluate(records,16,1,mode)
            self.assertEqual(counts['errors'],errors)
            self.assertEqual(counts['queries'],len(records))
            self.assertEqual(counts.get('replayed_queries',0),0)

    def test_replay_conserves_resolution_count(self):
        records=[(0x100+4*(i%7),0,bool((i^(i>>2))&1),0x80,0,0) for i in range(317)]
        for delay in [2,4,7]:
            for mode in ['resolved','oracle-prefix','speculative']:
                counts=timing.evaluate(records,16,delay,mode)
                self.assertEqual(counts['resolved'],len(records))
                self.assertEqual(counts['queries']-counts.get('replayed_queries',0),len(records))

if __name__=='__main__':unittest.main()
