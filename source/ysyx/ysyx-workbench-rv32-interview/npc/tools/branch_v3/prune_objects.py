#!/usr/bin/env python3
"""Keep executables and evidence; remove reproducible objects from linked builds."""
import hashlib
import json
import os
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
# Safety suites keep their source, generated C++, executables, logs and result
# contracts. Only the four-goal completed suites qualify for object pruning.
required={'test-fetch','test-fence-i','test-dcache-recovery','test-precise-exception'}
for result in (ROOT/'safety').glob('*/results.json'):
    checks=json.loads(result.read_text())
    if len(checks)!=4 or any(c['returncode'] for c in checks):
        continue
    if {c['command'][-1] for c in checks}!=required:
        continue
    folder=result.parent
    executables=[p for p in folder.rglob('V*') if p.is_file() and os.access(p,os.X_OK)]
    if not executables:
        continue
    hashes={str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest() for p in executables}
    removed=[]
    for file in folder.rglob('*'):
        if file.is_file() and file.suffix in ('.o','.a','.gch'):
            removed.append({'name':str(file.relative_to(folder)),'bytes':file.stat().st_size})
            file.unlink()
    for name,digest in hashes.items():
        assert hashlib.sha256((folder/name).read_bytes()).hexdigest()==digest
    if removed:
        records.append({'build':'safety/'+folder.name,'executables_sha256':hashes,'removed':removed})
        (ROOT/'object-pruning.json').write_text(json.dumps(records,indent=2)+'\n')
(ROOT/'object-pruning.json').write_text(json.dumps(records,indent=2)+'\n')
print('Removed only linked-build objects:',sum(v['bytes'] for r in records for v in r['removed']),'bytes; binaries unchanged')
