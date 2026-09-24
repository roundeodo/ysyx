#!/usr/bin/env python3
"""Compact completed history-study evidence without removing runnable binaries."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
from buffer_history_training import TOP


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve()
    for name in ['audit.json', 'completion.json']:
        assert json.loads((root / name).read_text())['status'] == 'passed'
    record_path = root / 'artifact-compaction.json'
    record = json.loads(record_path.read_text()) if record_path.exists() else {
        'compressed': [], 'removed_duplicates': [], 'bytes_released': 0}

    def save():
        record_path.write_text(json.dumps(record, indent=2) + '\n')

    paths = list(root.glob('ppa/*/synthesis.log'))
    paths += list(root.glob('ppa/*/sta/*/yosys.log'))
    paths += list(root.glob('ppa/*/sta/*/before.json'))
    for path in paths:
        if path.stat().st_size < 1024 * 1024:
            continue
        target = path.with_name(path.name + '.gz')
        assert not target.exists(), target
        original_hash, original_bytes = sha(path), path.stat().st_size
        with path.open('rb') as source, gzip.open(target, 'wb', compresslevel=1) as dest:
            shutil.copyfileobj(source, dest)
        h = hashlib.sha256()
        with gzip.open(target, 'rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                h.update(block)
        assert h.hexdigest() == original_hash
        released = original_bytes - target.stat().st_size
        record['compressed'].append({'original': str(path.relative_to(root)),
            'path': str(target.relative_to(root)), 'original_sha256': original_hash,
            'sha256': sha(target), 'original_bytes': original_bytes})
        record['bytes_released'] += released
        save()
        path.unlink()

    # Frequency-specific STA inputs are identical copies of the mapped design.
    # Retain that canonical input plus every constraint and timing report.
    for folder in sorted((root / 'ppa').iterdir()):
        canonical = folder / f'sta/{TOP}-820MHz-buffered/{TOP}.netlist.v'
        if not canonical.exists():
            continue
        expected = sha(canonical)
        for path in folder.glob(f'sta/*-buffered/{TOP}.netlist.v'):
            if path == canonical or sha(path) != expected:
                continue
            record['removed_duplicates'].append({'path': str(path.relative_to(root)),
                'identical_retained_path': str(canonical.relative_to(root)),
                'sha256': expected, 'bytes': path.stat().st_size})
            record['bytes_released'] += path.stat().st_size
            save()
            path.unlink()
    record['status'] = 'completed'
    save()
    print('PASS compact artifacts; released', record['bytes_released'], 'bytes')


if __name__ == '__main__':
    main()
