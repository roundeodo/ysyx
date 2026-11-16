#!/usr/bin/env python3
"""Losslessly compress completed traces; offline readers accept both forms."""
import argparse
import fcntl
import gzip
import hashlib
import json
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--primary', action='store_true', help='Also compress completed primary traces')
    args = parser.parse_args()
    manifest = ROOT/'trace-compression.json'
    with (ROOT/'trace-compression.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        records = json.loads(manifest.read_text()) if manifest.exists() else []
        count = 0
        for index in sorted((ROOT/'rtl').glob('*/index.json')):
            secondary = any(token in index.parent.name for token in ('MHz','-real','-sensitivity-','-layout-'))
            if not args.primary and not secondary:
                continue
            for source in sorted(index.parent.iterdir()):
                if source.suffix not in ('.events', '.trace'):
                    continue
                target = Path(str(source)+'.gz')
                if target.exists():
                    continue
                temporary = Path(str(target)+'.tmp')
                original = hashlib.sha256()
                with source.open('rb') as raw, gzip.open(temporary, 'wb', compresslevel=1) as compressed:
                    for chunk in iter(lambda: raw.read(1048576), b''):
                        original.update(chunk)
                        compressed.write(chunk)
                restored = hashlib.sha256()
                with gzip.open(temporary, 'rb') as raw:
                    for chunk in iter(lambda: raw.read(1048576), b''):
                        restored.update(chunk)
                assert original.digest() == restored.digest()
                temporary.replace(target)
                records.append({'original': str(source.relative_to(NPC)), 'sha256': original.hexdigest(),
                                'original_bytes': source.stat().st_size,
                                'compressed': str(target.relative_to(NPC)),
                                'compressed_bytes': target.stat().st_size})
                temporary_manifest = manifest.with_suffix('.json.tmp')
                temporary_manifest.write_text(json.dumps(records, indent=2)+'\n')
                temporary_manifest.replace(manifest)
                source.unlink()
                count += 1
                if count % 100 == 0:
                    print('Compressed and verified', count, 'new traces', flush=True)
        print('PASS lossless compression', len(records),
              sum(row['original_bytes']-row['compressed_bytes'] for row in records), 'bytes saved')


if __name__ == '__main__':
    main()
