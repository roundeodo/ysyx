#!/usr/bin/env python3
"""Losslessly compress reset-tree intermediates only after full PPA qualification."""
import gzip,hashlib,json,os
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3';manifest=ROOT/'ppa-json-compression.json'
records=json.loads(manifest.read_text()) if manifest.exists() else []
for q in sorted((ROOT/'ppa').glob('*/qualified.json')):
 for name in ('before.json','buffered.json'):
  source=q.parent/'sta/riscv32_core_reset_boundary-820MHz-buffered'/name
  if not source.exists():continue
  target=Path(str(source)+'.gz');temporary=Path(str(target)+'.partial')
  assert not target.exists() and not temporary.exists()
  original=hashlib.sha256()
  with source.open('rb') as raw,gzip.open(temporary,'wb',compresslevel=1) as compressed:
   for chunk in iter(lambda:raw.read(1048576),b''):original.update(chunk);compressed.write(chunk)
  restored=hashlib.sha256()
  with gzip.open(temporary,'rb') as raw:
   for chunk in iter(lambda:raw.read(1048576),b''):restored.update(chunk)
  assert restored.digest()==original.digest()
  os.replace(temporary,target)
  records.append({'source':str(source.relative_to(NPC)),'compressed':str(target.relative_to(NPC)),
                  'sha256_uncompressed':original.hexdigest(),'original_bytes':source.stat().st_size,'compressed_bytes':target.stat().st_size})
  manifest.write_text(json.dumps(records,indent=2)+'\n');source.unlink()
  print('PASS lossless',q.parent.name,name,flush=True)
print('Saved bytes',sum(r['original_bytes']-r['compressed_bytes'] for r in records))
