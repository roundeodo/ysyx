#!/usr/bin/env python3
"""Opportunity accounting at resolved/decoded M0 timing; no CPU-time estimates."""
import json,collections
from pathlib import Path
from targets import TargetTable,IndirectHistory
NPC=Path(__file__).resolve().parents[2];root=NPC/'result/branch-v3';records=[]
for file in sorted((root/'rtl/B0').glob('*.events')):
    instructions={int(x[0],16):int(x[1],16) for x in (line.strip().split(',') for line in file.with_suffix('.trace').open())}
    tables={n:TargetTable(n) for n in [16,32,64,128]};fast=TargetTable(4);slow=TargetTable(32)
    indirect=IndirectHistory();ras={n:[] for n in [4,8,16]};counts=collections.Counter();sites=collections.defaultdict(set)
    for line in file.open():
        x=line.strip().split(',')
        if x[0]!='R':continue
        pc,target,kind=int(x[3],16),int(x[4],16),int(x[5]);taken=bool(int(x[6]));ins=instructions[pc]
        rd=(ins>>7)&31;rs1=(ins>>15)&31
        is_return=kind==3 and rs1 in (1,5) and (rd not in (1,5) or rd!=rs1)
        is_call=kind in (2,3) and rd in (1,5)
        label='conditional' if kind==1 else 'direct' if kind==2 else 'return' if is_return else 'indirect'
        counts[label]+=1
        if taken:
            for n,t in tables.items():
                guess=t.lookup(pc)
                counts[f'btb{n}_{label}_miss']+=guess is None
                counts[f'btb{n}_{label}_wrong']+=guess is not None and guess!=target
            f,s=fast.lookup(pc),slow.lookup(pc)
            counts['tier_late_correct']+=f!=target and s==target
            counts['tier_harmful_override']+=f==target and s is not None and s!=target
            if kind in (1,2):counts['decoded_exact_direct_targets']+=1
            if is_return:
                for n,stack in ras.items():
                    counts[f'ras{n}_decoded_return_wrong']+=not stack or stack[-1]!=target
                    counts[f'ras{n}_request_btb_missing']+=tables[16].lookup(pc) is None
            elif kind==3:
                guess,context=indirect.lookup(pc)
                counts['indirect_history_wrong']+=guess!=target
                counts['indirect_last_wrong']+=indirect.base.lookup(pc)!=target
                sites[pc].add(target);indirect.train(context,target)
        for n,stack in ras.items():
            if is_return and stack:stack.pop()
            if is_call:
                if len(stack)==n:counts[f'ras{n}_overflow']+=1;stack.pop(0)
                stack.append((pc+4)&0xffffffff)
        for t in [*tables.values(),fast,slow]:t.train(pc,target)
        indirect.advance_path(pc,target,taken)
    records.append({'case':file.stem,'layer':'M0-decoded-immediate-ROI-cold','counts':dict(counts),'indirect_distinct_targets':{hex(pc):len(ts) for pc,ts in sites.items()},'limits':'Tier latency and speculative RAS rollback are not modeled. Full decoded RAS is a timing-specific diagnostic. IndirectHistory is a small path-tagged prototype, not full ITTAGE.'})
(NPC/'docs/research/branch-v3/target-diagnostics.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS target diagnostics',len(records))
