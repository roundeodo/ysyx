#!/usr/bin/env python3
"""Run the frozen final matrix without selecting algorithms or clock frequencies."""
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import subprocess
import sys
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3'
TOOL = Path(__file__).resolve().parent


def main():
    freeze_path = NPC/'docs/research/branch-v3/selection-freeze.json'
    freeze = json.loads(freeze_path.read_text())
    assert freeze['schema'] == 2, 'This runner requires the completed BTB validation freeze'
    digest = hashlib.sha256(freeze_path.read_bytes()).hexdigest()
    output = ROOT/'final-execution.json'
    record = json.loads(output.read_text()) if output.exists() else {
        'freeze_sha256': digest, 'runs': [], 'status': 'started, no retuning allowed'}
    assert record['freeze_sha256'] == digest
    output.write_text(json.dumps(record, indent=2)+'\n')
    builds = [
        ('images-final', [sys.executable, str(NPC/'scripts/build_branch_workloads.py'),
                          '--output', str(ROOT/'images-final'), '--dev-seeds', '2411', '2418',
                          '--held-seeds', '2467', '2474']),
        ('streams-final', [sys.executable, str(TOOL/'build_streams.py'), '--split', 'final']),
        ('streams-long-paired-final', [sys.executable, str(TOOL/'build_long_streams.py'),
                                      '--split', 'final', '--paired-windows'])]
    for dataset, command in builds:
        if (ROOT/dataset/'manifest.json').exists():
            continue
        with (ROOT/f'build-{dataset}.log').open('x') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    jobs = []
    for name, candidate in freeze['candidates'].items():
        for mhz in candidate['mhz']:
            for images in ['images-final', 'streams-final']:
                jobs.append((name, mhz, images))
        jobs.append((name, candidate['operating_mhz'], 'streams-long-paired-final'))

    def measure(job):
        name, mhz, images = job
        label = f'{name}-final-{mhz}MHz-{images}'
        index = ROOT/'rtl'/label/'index.json'
        command = [sys.executable, str(TOOL/'run_core.py'), 'run', '--name', name,
                   '--label', label, '--mhz', str(mhz), '--images', str(ROOT/images),
                   '--compact', '--branch-window', '8192', '--max-cycles', '200000000', '--final']
        if images == 'streams-long-paired-final':
            for kind in ['jsmn', 'miniz']:
                for window in ['cold', 'warm']:
                    command += ['--case', f'{kind}_long-128-{window}']
        if not index.exists():
            with (ROOT/(label+'.driver.log')).open('a') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        else:
            # Verify exact invocation and frozen binary even on completed reuse.
            subprocess.run(command, stdout=subprocess.DEVNULL, check=True)
        return {'command': command, 'index': str(index), 'label': label}

    with ThreadPoolExecutor(max_workers=4) as pool:
        pending = [pool.submit(measure, job) for job in jobs]
        for future in as_completed(pending):
            completed = future.result()
            if not any(row['label'] == completed['label'] for row in record['runs']):
                record['runs'].append(completed)
            output.write_text(json.dumps(record, indent=2)+'\n')
            print('PASS frozen final', completed['label'], flush=True)
    assert len(record['runs']) == len(jobs)
    record['status'] = 'completed without retuning'
    output.write_text(json.dumps(record, indent=2)+'\n')


if __name__ == '__main__':
    main()
