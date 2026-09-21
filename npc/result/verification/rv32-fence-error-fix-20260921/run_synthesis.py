#!/usr/bin/env python3
"""Freeze the candidate RTL and synthesize using the established comparison flow."""
from pathlib import Path
import json,hashlib,os,subprocess,shutil,sys
out=Path(__file__).resolve().parent
root=out.parents[3]
npc=root/'npc'
snapshot=out/'synthesis-source'
snapshot.mkdir(exist_ok=False)
sources=[Path(x.strip().replace('${NPC_HOME}',str(npc))) for x in (npc/'vsrc/riscv32/filelist/filelist_sta.f').read_text().splitlines() if x.strip().startswith('${NPC_HOME}')]
hashes={}
rtl_source=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else npc/'vsrc/riscv32'
for p in sources:
 name=p.relative_to(root);actual=rtl_source/p.relative_to(npc/"vsrc/riscv32");dst=snapshot/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(actual,dst)
 hashes[str(name)]=hashlib.sha256(actual.read_bytes()).hexdigest()
(out/'synthesis-source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
command=json.loads((npc/'result/performance/rv32-precise-exception-20260919/synthesis-command.json').read_text())
for i,x in enumerate(command):
 if x.startswith('STA_OUTPUT_ROOT='): command[i]='STA_OUTPUT_ROOT='+str(out/'sta')
 if x.startswith('STA_RTL_DEPENDENCIES='): command[i]='STA_RTL_DEPENDENCIES='+' '.join(str(snapshot/p.relative_to(root)) for p in sources)
(out/'synthesis-command.json').write_text(json.dumps(command,indent=2)+'\n')
env=dict(os.environ,NPC_HOME=str(npc),AM_HOME=str(root/'abstract-machine'),NEMU_HOME=str(root/'nemu'))
with (out/'synthesis.log').open('w') as f:r=subprocess.run(command,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
(out/'synthesis.exit').write_text(str(r.returncode)+'\n')
print('Synthesis exit',r.returncode,flush=True)
if r.returncode: print((out/'synthesis.log').read_text()[-5000:])
raise SystemExit(r.returncode)
