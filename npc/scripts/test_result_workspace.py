import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parent))
from result_workspace import ResultWorkspace

class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.npc = Path(self.temp.name)/'npc'
        self.root = self.npc/'result/current'
    def runspace(self, **kw):
        return ResultWorkspace(self.npc,self.root,'test',**kw)
    def test_unmanaged_preserved(self):
        self.root.mkdir(parents=True)
        source=self.root/'source.sv';source.write_text('user RTL')
        with self.assertRaises(ValueError):
            with self.runspace():pass
        self.assertEqual(source.read_text(),'user RTL')
    def test_success_archive_and_overwrite(self):
        with self.runspace():
            for name in ['build','source','sta']:
                (self.root/name).mkdir();(self.root/name/'large').write_text('artifact')
            (self.root/'report.json').write_text('{"total": 123}')
            (self.root/'simulator').write_text('binary')
            (self.root/'large.log').write_text('x'*100000)
        history=json.loads((self.root/'retention.json').read_text())['history']
        self.assertEqual(json.loads((Path(history)/'report.json').read_text())['total'],123)
        self.assertFalse((self.root/'build').exists())
        self.assertFalse((self.root/'simulator').exists())
        self.assertLess((self.root/'large.log').stat().st_size,66000)
        with self.runspace():
            self.assertFalse((self.root/'report.json').exists())
            (self.root/'report.json').write_text('{"total": 456}')
        self.assertEqual(json.loads((Path(history)/'report.json').read_text())['total'],123)
    def test_failure_then_retry(self):
        with self.assertRaises(RuntimeError):
            with self.runspace():
                (self.root/'build').mkdir()
                (self.root/'configuration.json').write_text('{}')
                raise RuntimeError('test')
        self.assertTrue((self.root/'build').exists())
        with self.runspace():self.assertFalse((self.root/'build').exists())
    def test_keep_resume(self):
        with self.runspace(keep=True):(self.root/'simulator').write_text('binary')
        with self.runspace(resume=True):self.assertTrue((self.root/'simulator').exists())
        self.assertFalse((self.root/'simulator').exists())
    def test_missing_resume(self):
        with self.assertRaises(ValueError):
            with self.runspace(resume=True):pass
    def test_lock(self):
        with self.runspace():
            with self.assertRaises(BlockingIOError):
                with self.runspace():pass
    def test_active_legacy_process(self):
        self.root.mkdir(parents=True)
        child=subprocess.Popen([sys.executable,'-c','import time; print("ready",flush=True); time.sleep(30)'],cwd=self.root,stdout=subprocess.PIPE,text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(),'ready')
            with self.assertRaises(RuntimeError):
                with self.runspace():pass
        finally:
            child.terminate();child.wait();child.stdout.close()
    def test_external_rejected(self):
        with self.assertRaises(ValueError):ResultWorkspace(self.npc,self.npc,'test')

if __name__=='__main__':unittest.main()
