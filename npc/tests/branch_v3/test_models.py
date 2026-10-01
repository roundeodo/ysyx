import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools/branch_v3'))
from models import Hybrid,ScaledTage,LocalHistory,sat,fold

class Contracts(unittest.TestCase):
    def test_local_private_history_and_saved_training(self):
        model = LocalHistory(entries=16, history_bits=3)
        first = model.lookup(0x100)
        model.train(first, True)
        self.assertEqual(model.histories[0], 1)
        second = model.lookup(0x100)
        model.train(first, True)
        self.assertEqual(model.histories[0], 3)
        self.assertEqual(model.counters[0][0], 3)
        self.assertEqual(model.counters[0][1], 1)
        model.train(second, True)
        self.assertEqual(model.counters[0][1], 2)
        self.assertEqual(model.lookup(0x140)['history'], 7)
        self.assertEqual(model.lookup(0x104)['history'], 0)
        model.invalidate()
        before = [row[:] for row in model.counters]
        model.train(second, False)
        self.assertEqual(model.counters, before)
        self.assertEqual(model.histories, [0]*16)
    def test_saturation(self):
        for value in range(4):
            self.assertEqual(sat(value,True),[1,2,3,3][value])
            self.assertEqual(sat(value,False),[0,0,1,2][value])
    def test_fold_definition(self):
        for h in range(1024):
            self.assertEqual(fold(h,10,3),sum((sum((h>>b)&1 for b in range(i,10,3))%2)<<i for i in range(3)))
    def test_agree_is_not_taken(self):
        m=Hybrid('h3');q=m.lookup(0x100,static=False);m.train(q,False)
        self.assertEqual(m.counters[0],2);self.assertFalse(m.lookup(0x100,static=False).prediction)
        q=m.lookup(0x100,static=False);m.train(q,True);self.assertEqual(m.counters[0],1)
    def test_unavailable_static_no_agree_training(self):
        m=Hybrid('h3');q=m.lookup(0x100,metadata_valid=False);m.train(q,True);self.assertEqual(m.counters[0],1)
    def test_chooser_only_disagreement(self):
        m=Hybrid('h4');q=m.lookup(0x100,static=False);m.train(q,False);self.assertEqual(m.chooser[0],1)
        q=m.lookup(0x100,static=True);m.train(q,True);self.assertEqual(m.chooser[0],0)
    def test_h1_real_tag_alias(self):
        m=Hybrid('h1');q=m.lookup(0x100,static=True);self.assertTrue(q.prediction);m.train(q,True)
        self.assertEqual(m.tags[0],0x100);self.assertFalse(m.lookup(0x140,static=False).prediction)
    def test_training_snapshot(self):
        m=Hybrid('gshare');q=m.lookup(0x100);m.history=15;m.train(q,True);self.assertEqual(m.counters[0],2)
    def test_invalidate_rejects_delayed_training(self):
        for m in [Hybrid('h4'),ScaledTage(sc=True,loop=True)]:
            q=m.lookup(0x100);m.invalidate();m.train(q,True)
            self.assertEqual(m.history,0)
    def test_scaled_allocation_and_stale_provider(self):
        m=ScaledTage();q=m.lookup(0x100);m.train(q,True);self.assertIsNotNone(m.tables[0][q['indices'][0]])
        m.history=0;q=m.lookup(0x100);p=q['provider'];self.assertEqual(p,0)
        entry=m.tables[p][q['indices'][p]];entry['tag']^=1;before=entry['ctr'];m.train(q,False);self.assertEqual(entry['ctr'],before)
    def test_loop_exit(self):
        m=ScaledTage(loop=True)
        for iteration in range(8):
            for t in [True,True,True,False]:m.train(m.lookup(0x100),t)
        for t in [True,True,True,False]:
            q=m.lookup(0x100);self.assertEqual(q['loop_prediction'],t);m.train(q,t)
    def test_sc_sum_width(self):
        m=ScaledTage(sc=True)
        for table in m.weights:table[:]=[15]*m.entries
        self.assertGreater(m.lookup(0x100)['sum'],31)
        for table in m.weights:table[:]=[-16]*m.entries
        self.assertLess(m.lookup(0x100)['sum'],-32)

if __name__=='__main__':unittest.main()
