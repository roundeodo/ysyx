#!/usr/bin/env python3
"""Losslessly compress completed full-state comparisons; preserve their reports."""
import gzip
import hashlib
import json
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3'
MANIFEST = ROOT/'model-compression.json'


def main():
    records = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else []
    for report in sorted((ROOT/'rtl').glob('*/model-check.json')):
        for source in sorted(report.parent.glob('*.model')):
            target = Path(str(source)+'.gz')
            assert not target.exists()
            original = hashlib.sha256()
            with source.open('rb') as raw, gzip.open(target, 'wb', compresslevel=1) as compressed:
                for chunk in iter(lambda: raw.read(1048576), b''):
                    original.update(chunk)
                    compressed.write(chunk)
            restored = hashlib.sha256()
            with gzip.open(target, 'rb') as raw:
                for chunk in iter(lambda: raw.read(1048576), b''):
                    restored.update(chunk)
            assert original.digest() == restored.digest()
            records.append({'source': str(source.relative_to(NPC)),
                            'compressed': str(target.relative_to(NPC)),
                            'sha256_uncompressed': original.hexdigest(),
                            'original_bytes': source.stat().st_size,
                            'compressed_bytes': target.stat().st_size})
            MANIFEST.write_text(json.dumps(records, indent=2)+'\n')
            source.unlink()
    print('PASS compressed model evidence; verified bytes saved:',
          sum(row['original_bytes']-row['compressed_bytes'] for row in records))


if __name__ == '__main__':
    main()
