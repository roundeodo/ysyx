#!/usr/bin/env python3
"""Share identical immutable frequency-probe netlists; retain every path and byte."""
import hashlib,json,os
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3';manifest=ROOT/'ppa-netlist-sharing.json'
records=json.loads(manifest.read_text()) if manifest.exists() else []
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for qualification in sorted((ROOT/'ppa').glob('*/qualified.json')):
 root=qualification.parent/'sta';source=root/'riscv32_core_reset_boundary-820MHz-buffered/riscv32_core_reset_boundary.netlist.v'
 digest=sha(source)
 for target in root.glob('*MHz-buffered/riscv32_core_reset_boundary.netlist.v'):
  if target==source or os.path.samefile(target,source):continue
  log=target.parent/'sta.log'
  if not log.exists() or 'The timing engine run success.' not in log.read_text():continue
  assert sha(target)==digest,(target,'frequency netlist changed')
  original=target.stat();temporary=target.with_name(target.name+'.shared')
  assert not temporary.exists();os.link(source,temporary);os.replace(temporary,target)
  assert sha(target)==digest
  records.append({'path':str(target.relative_to(NPC)),'canonical':str(source.relative_to(NPC)),
                  'sha256':digest,'bytes_shared':original.st_size,'original_mtime_ns':original.st_mtime_ns})
 manifest.write_text(json.dumps(records,indent=2)+'\n')
print('PASS identical immutable netlists shared; nominal duplicate bytes',sum(r['bytes_shared'] for r in records))
