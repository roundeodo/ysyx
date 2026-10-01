#!/usr/bin/env python3
"""Controlled RTL mutations must disagree with the unchanged independent model."""
import argparse,json,random,subprocess,hashlib,re
from pathlib import Path
from models import ScaledTage
from check_tage_scl import pack_context,pack_state
NPC=Path(__file__).resolve().parents[2];parser=argparse.ArgumentParser();parser.add_argument('--name',default='mutations');args=parser.parse_args();root=NPC/'result/branch-v3'/args.name;root.mkdir(exist_ok=False)
source=(NPC/'vsrc/riscv32/core/frontend/riscv32_tage_scl.sv').read_text()
mutations={
 'saturation':('value == high ? value : value + 1','value + 1'),
 'lookup_index':('lookup_pc_i[INDEX_BITS+1:2] ^ index_fold_q[b]','lookup_pc_i[INDEX_BITS+1:2] | index_fold_q[b]'),
 'snapshot':('assign training  = context_t\'(training_context_i);',"assign training = context_t'(context_o);"),
 'useful':('training.raw == training_taken_i,','training.raw != training_taken_i,'),
 'allocation':('for (int b = TABLE_COUNT - 1; b >= 0; b--)','for (int b = 0; b < TABLE_COUNT; b++)'),
 'sc_sign':("query.sum = 9'(total);","query.sum = -9'(total);"),
 'sc_threshold':('(training.sum >= 0) != training_taken_i, 1, 31','(training.sum >= 0) == training_taken_i, 1, 31'),
 'loop_exit':("({1'b0,loop_current_q[query.loop_index]}+9'd1)","({1'b0,loop_current_q[query.loop_index]}+9'd0)"),
 'alternate_selector':('training.alt == training_taken_i, -8, 7','training.alt != training_taken_i, -8, 7'),
}
rng=random.Random(9871);m=ScaledTage(sc=True,loop=True);saved=[None]*64;rows=[];expected=[]
for cycle in range(4000):
 slot=cycle%64;ts=(cycle-(1 if cycle<500 else rng.randrange(1,33)))%64
 pc=0x100 if cycle<500 else 0x100+4*rng.randrange(128)
 tv=saved[ts] is not None;taken=cycle%4!=3 if cycle<500 else bool(rng.randrange(2));iv=cycle==1700
 q=m.lookup(pc)
 if iv:m.invalidate()
 elif tv:m.train(saved[ts],taken)
 expected.append((int(q['prediction']),pack_context(q),pack_state(m)));saved[slot]=q
 rows.append(f'{pc:x} {slot} {ts} {int(tv)} {int(taken)} {int(iv)}\n')
vectors=root/'vectors.txt';vectors.write_text(''.join(rows));results=[]
for name,(old,new) in mutations.items():
 folder=root/name;folder.mkdir()
 pattern=r'\s*'.join(re.escape(token) for token in re.findall(r'[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[^\s]',old))
 matches=list(re.finditer(pattern,source));assert len(matches)==1,(name,len(matches))
 mutated=re.sub(pattern,lambda match:new,source,count=1)
 rtl=folder/'riscv32_tage_scl.sv';rtl.write_text(mutated)
 command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2','--top-module','tage_scl_tb','-GSC_ENABLE=1','-GLOOP_ENABLE=1','+define+BRANCH_V3_VERIFY','--Mdir',str(folder/'obj'),str(rtl),str(NPC/'tests/branch_v3/tage_scl_tb.sv')]
 with (folder/'build.log').open('x') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
 output=folder/'actual.txt'
 with (folder/'run.log').open('x') as f:subprocess.run([str(folder/'obj/Vtage_scl_tb'),f'+input={vectors}',f'+output={output}'],stdout=f,stderr=subprocess.STDOUT,check=True)
 first=None
 lines=output.read_text().splitlines();assert len(lines)==len(expected)
 for i,(line,ref) in enumerate(zip(lines,expected)):
  x=line.split();got=(int(x[0]),int(x[1],16),int(x[2],16))
  if got!=ref:first=i;break
 result={'mutation':name,'status':'detected' if first is not None else 'not-detected','first_difference':first,'source_sha256':hashlib.sha256(mutated.encode()).hexdigest()}
 results.append(result);(root/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(result,flush=True)
