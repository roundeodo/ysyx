#!/usr/bin/env python3
"""Keep executables and evidence; remove reproducible objects from linked builds."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]/'result/branch-v3'
manifest=ROOT/'object-pruning.json'
records=json.loads(manifest.read_text()) if manifest.exists() else []
for manifest in (ROOT/'builds').glob('*/manifest.json'):
    binary=manifest.parent/'obj/Vexploration_core_tb'
    if not binary.exists():
        continue
    before=hashlib.sha256(binary.read_bytes()).hexdigest()
    removed=[]
    for file in (manifest.parent/'obj').iterdir():
        if file.is_file() and file.suffix in ('.o','.a','.gch'):
            removed.append({'name':file.name,'bytes':file.stat().st_size})
            file.unlink()
    assert hashlib.sha256(binary.read_bytes()).hexdigest()==before
    if removed:
        records.append({'build':manifest.parent.name,'binary_sha256':before,'removed':removed})
(ROOT/'object-pruning.json').write_text(json.dumps(records,indent=2)+'\n')
print('Removed only linked-build objects:',sum(v['bytes'] for r in records for v in r['removed']),'bytes; binaries unchanged')
