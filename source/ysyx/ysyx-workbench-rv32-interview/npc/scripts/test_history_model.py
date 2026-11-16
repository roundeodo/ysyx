#!/usr/bin/env python3
"""Check learning capability, stale identity and saturation before screening."""
import random
import unittest
from model_history import SmallTage, CounterTable, fold

class HistoryTests(unittest.TestCase):
    def test_fold(self):
        self.assertEqual(fold(0b101101,3,6),0b101 ^ 0b101)
        self.assertEqual(fold(0xffff,8,16),0)

    def test_xor_correlation(self):
        rng=random.Random(41);models=[SmallTage(32),CounterTable(32)];errors=[0,0]
        for iteration in range(6000):
            a,b=bool(rng.getrandbits(1)),bool(rng.getrandbits(1))
            for pc,taken in [(0x100,a),(0x104,b),(0x108,a ^ b)]:
                for i,model in enumerate(models):
                    pred=model.predict(pc,pc-8)
                    if pc==0x108 and iteration>1000:errors[i]+=pred != taken
                    model.update(pc,pc-8,taken)
        self.assertLess(errors[0],errors[1]//3,errors)

    def test_stale_identity(self):
        model=SmallTage(8);pc=0x100
        index,tag=model.addresses(pc,0)[2]
        model.banks[2][index]=[tag,7,1]
        query=model.lookup(pc)
        self.assertEqual(query['provider'],3)
        model.banks[2][index]=[tag ^ 1,6,1]
        model.train(query,False)
        self.assertEqual(model.banks[2][index],[tag ^ 1,6,1])
        self.assertEqual(model.stats['stale_provider'],1)

    def test_train_snapshot_not_current_history(self):
        model=SmallTage(16);pc=0x100
        query=model.lookup(pc);model.history=0xacf2
        model.train(query,True)
        index,tag=model.addresses(pc,0)[0]
        self.assertEqual(model.banks[0][index],[tag,4,0])

    def test_saturation(self):
        model=SmallTage(8)
        for taken in [True]*100+[False]*100:
            query=model.lookup(0x100);model.train(query,taken)
        self.assertTrue(all(0<=v<=3 for v in model.base))
        self.assertTrue(all(0<=e[1]<=7 for bank in model.banks for e in bank if e))

if __name__=='__main__':unittest.main()
