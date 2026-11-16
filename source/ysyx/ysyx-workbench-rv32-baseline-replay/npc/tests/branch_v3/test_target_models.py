"""Range, identity lifetime and information-availability checks for target models."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools/branch_v3'))
from target_models import Btb, Metadata, Prefill, decode


class TargetTests(unittest.TestCase):
    def test_direct_decode(self):
        self.assertEqual(decode(0x80000000, 0x0000006f), (1, 0x80000000, 0))
        self.assertEqual(decode(0x80000000, 0xfe000ee3), (0, 0x7ffffffc, -4))
        self.assertEqual(decode(0x80000000, 0x00008067)[0], 3)
        self.assertIsNone(decode(0x80000000, 0x00000013)[0])

    def test_compact_migration_and_rejection(self):
        pc = 0x80000004
        table = Btb(entries=16, ways=2, index=0, policy=0, admission=1, widths=[16, 32])
        table.train(pc, 0x80001234, 1, True)
        self.assertEqual(table.lookup(pc)[0], 0x80001234)
        table.train(pc, 0x81001234, 1, True)
        self.assertEqual(table.lookup(pc)[0], 0x81001234)
        self.assertEqual(sum(e is not None and e[0] == pc for row in table.rows for e in row), 1)
        narrow = Btb(entries=16, ways=2, index=0, policy=0, admission=1, widths=[16, 16])
        narrow.train(pc, 0x80001234, 1, True)
        narrow.train(pc, 0x81001234, 1, True)
        self.assertIsNone(narrow.lookup(pc))
        self.assertEqual(narrow.rejected, 1)

    def test_region_reuse_invalidates_all_users(self):
        table = Btb(regions=2)
        for pc in (0x80000004, 0x80000044):
            table.train(pc, 0x81001234, 1, True)
        table.train(0x80000008, 0x82005678, 1, True)
        table.train(0x8000000c, 0x83009abc, 1, True)
        self.assertIsNone(table.lookup(0x80000004))
        self.assertIsNone(table.lookup(0x80000044))
        self.assertEqual(table.lookup(0x80000008)[0], 0x82005678)
        self.assertEqual(table.lookup(0x8000000c)[0], 0x83009abc)

    def test_metadata_not_visible_before_install(self):
        meta = Metadata()
        meta.apply([['L', '1', '0', '0', '0', '80000000']])
        for word in range(8):
            meta.apply([['D', str(word+2), '0', '0', str(word), '0000006f']])
        self.assertIsNone(meta.lookup(0x80000000))
        installs = meta.apply([['L', '10', '0', '0', '1', '80000000']])
        self.assertEqual(meta.lookup(0x80000000), (1, 0x80000000, 0))
        self.assertEqual(len(installs), 1)
        meta.apply([['V', '11']])
        self.assertIsNone(meta.lookup(0x80000000))

    def test_prefill_bandwidth_and_training_priority(self):
        model = Prefill()
        model.enqueue([(0x80000000, {i: 0x0000006f for i in range(8)})])
        self.assertEqual(len(model.queue), 4)
        self.assertEqual(model.dropped, 4)
        self.assertIsNone(model.table.lookup(0x80000000))
        model.tick()
        self.assertEqual(model.table.lookup(0x80000000)[0], 0x80000000)
        self.assertIsNone(model.table.lookup(0x80000004))
        model.table.train(0x80000004, 0x81001234, 1, True)
        model.tick()
        self.assertEqual(model.table.lookup(0x80000004)[0], 0x81001234)
        model.clear()
        self.assertFalse(model.queue)
        self.assertIsNone(model.table.lookup(0x80000004))


if __name__ == '__main__':
    unittest.main()
