#!/usr/bin/env python3
"""Verify the complete-device timing bridge, including its shared-SDRAM counterexample."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess

NPC = Path(__file__).resolve().parents[1]
SOC = NPC.parent / 'ysyxSoC'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=NPC / 'build/tests/device-timing')
    parser.add_argument('--cpu-mhz', type=int, nargs='+', default=[100, 200, 250, 580, 720])
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    common = [SOC / 'perip/amba/device_clock.v', SOC / 'perip/amba/axi4_delayer.v',
              SOC / 'perip/amba/apb_delayer.v']
    pmem = SOC / 'perip/sdram/core_sdram_axi4/sdram_axi_pmem.v'
    groups = {'apb': [], 'axi_stress': [], 'axi': [pmem],
              'sdram': [SOC / 'perip/sdram/sdram_top_axi.v', SOC / 'perip/sdram/sdram.v',
                        pmem, SOC / 'perip/sdram/core_sdram_axi4/sdram_axi.v',
                        SOC / 'perip/sdram/core_sdram_axi4/sdram_axi_core.v']}

    def run_case(case):
        kind, mhz = case
        top = f'device_clock_{kind}_tb'
        directory = output / f'{kind}-{mhz}'
        directory.mkdir(exist_ok=True)
        sources = common + groups[kind] + [NPC / 'tests/rtl' / (top + '.sv')]
        command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
                   '--top-module', top, f'-GCPU_MHZ={mhz}', '--Mdir', str(directory / 'obj')]
        command += list(map(str, sources))
        record = {'kind': kind, 'cpu_mhz': mhz, 'device_mhz': 100, 'command': command,
                  'sources': {str(p.relative_to(NPC.parent)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sources}, 'logs': [], 'passed': False}
        (directory / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
        with (directory / 'build.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        binary = directory / 'obj' / ('V' + top)
        records = []
        for late in ([0, 1] if kind == 'axi' else [None]):
            name = f'run-{late}.log' if late is not None else 'run.log'
            command = [str(binary)] + ([f'+LATE_READ={late}'] if late is not None else [])
            with (directory / name).open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            record['logs'].append(str((directory / name).relative_to(output)))
            text = (directory / name).read_text()
            if kind == 'axi':
                records.append(json.loads(next(line for line in text.splitlines() if line.startswith('{'))))
            elif 'PASS' not in text:
                raise RuntimeError(f'Missing PASS: {directory / name}')
        if kind == 'axi':
            if records[0]['r_up'] > records[1]['r_up']:
                raise RuntimeError(f'Early read penalized by double scaling: {records}')
            record['shared_sdram'] = records
        record['passed'] = True
        (directory / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print(f'PASS {kind} CPU={mhz} MHz device=100 MHz', flush=True)
        return record

    cases = [(kind, mhz) for mhz in args.cpu_mhz for kind in groups]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run_case, cases))
    (output / 'summary.json').write_text(json.dumps({'schema': 1, 'model': 'device-clock-v1',
                                                   'passed': True, 'cases': results}, indent=2) + '\n')


if __name__ == '__main__':
    main()
