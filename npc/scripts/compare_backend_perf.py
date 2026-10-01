#!/usr/bin/env python3
"""Compare qualified backends at a common legal clock and their own legal clocks."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ppa-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    definitions = [('retained-legacy', 0, 4, 0), ('retained2', 1, 2, 1),
                   ('retained4', 1, 4, 1), ('retained8', 1, 8, 1),
                   ('retained4-noload', 1, 4, 0)]
    configs = []
    for name, enabled, entries, overlap in definitions:
        root = args.ppa_root.resolve() / name
        qualification = json.loads((root / 'qualified.json').read_text())
        if not qualification['all_groups_passed']:
            raise RuntimeError(f'Unqualified clock: {name}')
        configs.append((name, enabled, entries, overlap, qualification))
    common = min(config[4]['mhz'] for config in configs)
    report = {'scale': 'test', 'common_mhz': common, 'rows': [],
              'note': 'Native timer plus passive IPC; each frequency rebuilds the device-clock delay model.'}
    image_hashes = set()
    for name, enabled, entries, overlap, qualification in configs:
        for mhz in sorted({common, qualification['mhz']}):
            run_dir = out / f'{name}-{mhz}'
            command = ['python3', str(NPC / 'scripts/run_microbench_perf.py'),
                       '--scale', 'test', '--isa', 'rv32im', '--mul-pipeline', '1',
                       '--backend-rob', str(enabled), '--backend-entries', str(entries),
                       '--load-overlap', str(overlap), '--cpu-mhz', str(mhz),
                       '--icache-bytes', '1024', '--icache-ways', '4', '--icache-line', '32',
                       '--icache-policy', '13', '--output', str(run_dir)]
            if not (run_dir / 'report.json').exists():
                print('RUN', name, mhz, flush=True)
                with (out / f'{name}-{mhz}.log').open('w') as stream:
                    subprocess.run(command, cwd=NPC.parent, stdout=stream,
                                   stderr=subprocess.STDOUT, check=True)
            measured = json.loads((run_dir / 'report.json').read_text())
            assert measured['status'] == 'passed' and measured['cpu_mhz'] == mhz
            assert measured['backend_rob'] == enabled and measured['backend_entries'] == entries
            assert measured['load_overlap'] == overlap
            digest = hashlib.sha256((run_dir / 'microbench.bin').read_bytes()).hexdigest()
            image_hashes.add(digest)
            row = {'name': name, 'mhz': mhz, 'common_clock': mhz == common,
                   'own_legal_clock': mhz == qualification['mhz'], 'image_sha256': digest,
                   'area_um2': qualification['area_um2'], 'total': measured['total'],
                   'scored': measured['scored'], 'command': command, 'report': str(run_dir / 'report.json')}
            row['area_times_total_seconds'] = row['area_um2'] * row['total']['cycle_seconds']
            report['rows'].append(row)
            (out / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
            print('PASS', name, mhz, row['total']['timer_seconds'], row['total']['ipc'], flush=True)
    if len(image_hashes) != 1:
        raise RuntimeError(f'Comparisons used different software images: {image_hashes}')
    report['identical_images'] = True
    (out / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
