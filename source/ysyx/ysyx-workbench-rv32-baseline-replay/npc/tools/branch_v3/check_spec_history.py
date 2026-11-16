#!/usr/bin/env python3
"""All four components with explicit query, repair, invalidation and stale contexts."""
import json,random,subprocess
from pathlib import Path
from models import SpeculativeTage
from check_tage_scl import pack_context,pack_state
NPC=Path(__file__).resolve().parents[2];root=NPC/'result/branch-v3/spec-unit';root.mkdir(exist_ok=False)
original=(NPC/'tests/branch_v3/tage_scl_tb.sv').read_text()
s=original.replace('.SC_ENABLE  (SC_ENABLE),','.SPECULATIVE_HISTORY(1),\n      .SC_ENABLE  (SC_ENABLE),')
s=s.replace(".lookup_handshake_i(1'b0),.lookup_conditional_i(1'b0),.lookup_taken_i(1'b0),.flush_i(1'b0)",'.lookup_handshake_i(accepted),.lookup_conditional_i(conditional),.lookup_taken_i(chosen),.flush_i(flush)')
s=s.replace('  int input_fd,','  bit accepted,conditional,chosen,flush;\n  int qa,qc,qt,fl;\n  int input_fd,')
s=s.replace('"%h %d %d %d %d %d\\n", pc, slot, train_slot, tv, tk, iv','"%h %d %d %d %d %d %d %d %d %d\\n", pc, slot, train_slot, tv, tk, iv,qa,qc,qt,fl').replace('if (rc != 6)','if (rc != 10)').replace("      invalidate = 1'(iv);","      invalidate = 1'(iv);\n      accepted=1'(qa);conditional=1'(qc);chosen=1'(qt);flush=1'(fl);")
(root/'tage_scl_tb.sv').write_text(s);results=[]
for sc,loop in [(0,0),(0,1),(1,0),(1,1)]:
 folder=root/f'sc{sc}-loop{loop}';folder.mkdir()
 command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2','--top-module','tage_scl_tb',f'-GSC_ENABLE={sc}',f'-GLOOP_ENABLE={loop}','+define+BRANCH_V3_VERIFY','--Mdir',str(folder/'obj'),str(NPC/'vsrc/riscv32/core/frontend/riscv32_tage_scl.sv'),str(root/'tage_scl_tb.sv')]
 with (folder/'build.log').open('x') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
 for seed in [117,821,993]:
  rng=random.Random(seed);model=SpeculativeTage(sc=sc,loop=loop);saved=[None]*64;expected=[];rows=[];coverage={'flush_train':0,'flush_only':0,'query_train':0,'invalidate_train':0}
  for cycle in range(3000):
   slot=cycle%64;ts=(cycle-rng.randrange(1,49))%64;pc=0x100+4*rng.randrange(64)
   tv=saved[ts] is not None and rng.randrange(4)!=0;taken=bool(rng.randrange(2));iv=cycle in (399,400,2101)
   accepted=rng.randrange(3)!=0;conditional=rng.randrange(4)!=0;chosen=bool(rng.randrange(2));flush=cycle%23==0
   q=model.lookup(pc);ctx=pack_context(q)
   coverage['flush_train']+=int(flush and tv);coverage['flush_only']+=int(flush and not tv)
   coverage['query_train']+=int(accepted and conditional and tv);coverage['invalidate_train']+=int(iv and tv)
   model.advance(accepted,conditional,chosen,saved[ts] if tv else None,taken,flush,iv)
   expected.append((int(q['prediction']),ctx,pack_state(model)));saved[slot]=q
   rows.append(f'{pc:x} {slot} {ts} {int(tv)} {int(taken)} {int(iv)} {int(accepted)} {int(conditional)} {int(chosen)} {int(flush)}\n')
  vectors=folder/f'{seed}.txt';vectors.write_text(''.join(rows));output=folder/f'{seed}.out'
  with (folder/f'{seed}.log').open('x') as f:subprocess.run([str(folder/'obj/Vtage_scl_tb'),f'+input={vectors}',f'+output={output}'],stdout=f,stderr=subprocess.STDOUT,check=True)
  lines=output.read_text().splitlines();assert len(lines)==len(expected)
  for i,(line,ref) in enumerate(zip(lines,expected)):
   fields=line.split();got=(int(fields[0]),int(fields[1],16),int(fields[2],16));assert got==ref,(sc,loop,seed,i)
  assert all(coverage.values());results.append({'sc':sc,'loop':loop,'seed':seed,'cycles':3000,'coverage':coverage,'status':'passed-full-state'})
  print('PASS speculative full-state',sc,loop,seed,flush=True)
(root/'results.json').write_text(json.dumps(results,indent=2)+'\n')
