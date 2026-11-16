"""Offline checks: never build or run train."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

NPC = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('compare', NPC / 'scripts/compare_soc_performance.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ComparisonTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        sources = {p: 'model-hash' for p in (
            'ysyxSoC/perip/amba/axi4_delayer.v', 'ysyxSoC/perip/amba/apb_delayer.v',
            'ysyxSoC/build/ysyxSoCFull.v', 'npc/scripts/run_microbench_perf.py')}
        self.manifest = dict(environment='ysyxSoC-sdram-calibrated', scale='train',
                             isa='rv64im_zicsr_zifencei', cpu_mhz=700, device_mhz=100,
                             timer_hz=1000000, delay_ratio_scaled=7168, delay_scale=1024,
                             layout={}, sources=sources, artifacts={}, configuration={
                                 'sdram_native_read_burst': '1', 'icache': '1024,4,32,13'})
        self.before = self.write('before', self.manifest)

    def write(self, name, manifest, cycles=1000, image=b'image'):
        manifest = copy.deepcopy(manifest)
        directory = self.root / name
        directory.mkdir()
        for artifact in ('microbench.bin', 'microbench.elf'):
            (directory / artifact).write_bytes(image)
            manifest['artifacts'][artifact] = hashlib.sha256(image).hexdigest()
        path = directory / 'manifest.json'
        path.write_text(json.dumps(manifest))
        window = dict(cycles=cycles, retired_instructions=100, ipc=100/cycles)
        report = dict(status='passed', scored=window, total=window,
                      manifest_sha256=module.digest(path), **{k: manifest[k] for k in
                          ('scale', 'cpu_mhz', 'device_mhz', 'timer_hz')})
        (directory / 'report.json').write_text(json.dumps(report))
        return directory

    def test_same_conditions_allow_core_configuration_change(self):
        changed = copy.deepcopy(self.manifest)
        changed['configuration']['icache'] = '2048,4,32,13'
        result = module.compare(self.before, self.write('after', changed, cycles=800))
        self.assertAlmostEqual(result['windows']['scored']['cycle_reduction_percent'], 20)
        self.assertIn('icache', result['configuration_changes'])

    def test_reject_different_scale_frequency_or_model(self):
        for key, value in [('scale', 'test'), ('cpu_mhz', 600), ('isa', 'rv32i')]:
            changed = copy.deepcopy(self.manifest)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.compare(self.before, self.write(key, changed))
        changed = copy.deepcopy(self.manifest)
        changed['sources']['ysyxSoC/perip/amba/axi4_delayer.v'] = 'other-model'
        with self.assertRaises(ValueError):
            module.compare(self.before, self.write('model', changed))

    def test_reject_different_program(self):
        with self.assertRaises(ValueError):
            module.compare(self.before, self.write('program', self.manifest, image=b'other'))

    def test_reject_changed_manifest(self):
        after = self.write('after', self.manifest)
        with (after / 'manifest.json').open('a') as file:
            file.write(' ')
        with self.assertRaises(ValueError):
            module.compare(self.before, after)


if __name__ == '__main__':
    unittest.main()
