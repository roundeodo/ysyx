#!/usr/bin/env python3
"""Losslessly compress completed secondary traces; keep primary evidence intact."""
import gzip
import hashlib
import json
from pathlib import Path

NPC=Path(__file__).resolve().parents[2]
root=NPC/'result/branch-v3'
manifest=root/'trace-compression.json'
records=json.loads(manifest.read_text()) if manifest.exists() else []
for index in sorted((root/'rtl').glob('*/index.json')):
    name=index.parent.name
    # These completed timing/secondary-input runs have no active trace reader.
    # Core model-check traces and primary development baselines are untouched.
    if not any(token in name for token in ('MHz','-real','-sensitivity-','-layout-')):
        continue
    for file in sorted(index.parent.iterdir()):
        if file.suffix not in ('.events','.trace'):
            continue
        target=Path(str(file)+'.gz')
        if target.exists():
            continue
        original=hashlib.sha256()
        with file.open('rb') as source, gzip.open(target,'wb',compresslevel=1) as compressed:
            for chunk in iter(lambda:source.read(1048576),b''):
                original.update(chunk);compressed.write(chunk)
        restored=hashlib.sha256()
        with gzip.open(target,'rb') as source:
            for chunk in iter(lambda:source.read(1048576),b''):restored.update(chunk)
        assert original.digest()==restored.digest()
        records.append({'original':str(file.relative_to(NPC)),'sha256':original.hexdigest(),
                        'original_bytes':file.stat().st_size,'compressed':str(target.relative_to(NPC)),
                        'compressed_bytes':target.stat().st_size})
        file.unlink()  # Only after a complete byte-for-byte-equivalent copy has been verified.
        (root/'trace-compression.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS lossless compression',len(records),sum(x['original_bytes']-x['compressed_bytes'] for x in records),'bytes saved')
