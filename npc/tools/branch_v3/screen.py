#!/usr/bin/env python3
"""M0 decoded-branch screening. This does not predict candidate CPU cycles."""
import json,subprocess
from pathlib import Path
from models import Hybrid, ScaledTage
NPC=Path(__file__).resolve().parents[2]
root=NPC/'result/branch-v3'
records=[]
for file in sorted((root/'rtl/B0').glob('*.events')):
    queries={};branches=[];cross={};ambiguous=0
    instructions = {int(x[0],16): int(x[1],16) for x in (line.strip().split(',') for line in file.with_suffix('.trace').open())}
    for line in file.open():
        x=line.strip().split(',')
        if x[0]=='Q':queries[int(x[1])]=int(x[3],16)
        elif x[0]=='R':
            id,pc=int(x[1]),int(x[3],16)
            assert queries.get(id)==pc,('dynamic identity',id,pc)
            target=int(x[4],16);kind=int(x[5]);taken=bool(int(x[6]))
            if kind==1:
                key=f'btb{int(x[8])}_raw{int(bool(int(x[7]))==taken)}_npc{1-int(x[10])}'
                cross[key]=cross.get(key,0)+1
                ambiguous+=target==(pc+4)&0xffffffff
            branches.append((pc,target,kind,taken))
    candidates=[(f'{p}-{n}',Hybrid(p,n)) for n in [16,64,256] for p in ['bimodal','gshare','static','nt','h1','h2','h3','h4']]
    candidates += [(f'scaled-tage-{n}-sc{int(sc)}-loop{int(lp)}',ScaledTage(base=n*2,entries=n,sc=sc,loop=lp)) for n in [16,32,64] for sc in [False,True] for lp in [False,True]]
    for name,model in candidates:
        errors=0;count=0;both={};learning=[]
        for pc,target,kind,taken in branches:
            if kind!=1:continue
            static=bool(((target-pc)&0xffffffff)>>31)
            q=model.lookup(pc,static=static,metadata_valid=True)
            prediction=q.prediction if isinstance(model,Hybrid) else q['prediction']
            errors+=prediction!=taken;count+=1
            k=f'static{int(static==taken)}_chosen{int(prediction==taken)}';both[k]=both.get(k,0)+1
            model.train(q,taken)
            if count%4096==0:learning.append([count,errors])
        records.append({'case':file.stem,'candidate':name,'layer':'M0-decoded-immediate-ROI-cold',
                        'bits_excluding_metadata_and_snapshots':model.bits,'branches':count,'errors':errors,
                        'static_vs_chosen':both,'learning':learning,'baseline_cross':cross,'target_equals_fallthrough':ambiguous})
    # Preserve RV32 control-flow types and byte PCs, no future outcome in GetPrediction.
    payload_rows=[]
    for pc,target,kind,taken in branches:
        instruction=instructions[pc]
        rd=(instruction>>7)&31;rs1=(instruction>>15)&31
        if kind==1: op=0
        elif kind==2: op=3 if rd in (1,5) else 1
        elif rd in (1,5): op=5
        elif rs1 in (1,5): op=4
        else: op=2
        payload_rows.append(f'{pc:x} {target:x} {op} {int(taken)}\n')
    payload=''.join(payload_rows)
    result=subprocess.run([str(root/'references/author8')],input=payload,text=True,capture_output=True,check=True)
    (root/'rtl/B0'/(file.stem+'.author-v2.log')).write_text(result.stdout+result.stderr)
    author=json.loads(next(l.strip() for l in result.stdout.splitlines() if l.strip().startswith('{')))
    records.append({'case':file.stem,'candidate':'author-CBP2016-8KB','layer':'M0-immediate-ROI-cold',**author})
out=NPC/'docs/research/branch-v3/m0-results-v2.json';out.write_text(json.dumps(records,indent=2)+'\n')
print(len(records),'measurements:',out)
