#!/usr/bin/env python3
"""M0 geometry/override accounting; never interpret errors as CPU cycles."""
import collections
import json
from pathlib import Path
from models import ScaledTage, Hybrid

NPC=Path(__file__).resolve().parents[2]
GEOMETRIES={
    'N-small':{'base':16,'entries':8,'lengths':(3,7),'tag_bits':6},
    'N-base16':{'base':16}, 'N-default':{}, 'N-base128':{'base':128},
    'N-tagged8':{'entries':8}, 'N-tagged32':{'entries':32},
    'N-tagged64':{'entries':64}, 'N-two':{'lengths':(3,7)},
    'N-tags6':{'tag_bits':6}, 'N-tags10':{'tag_bits':10},
    'N-h32':{'lengths':(4,13,32)},
}
records=[]
for path in sorted((NPC/'result/branch-v3/rtl/B0').glob('*.events')):
    branches=[]
    for line in path.open():
        f=line.strip().split(',')
        if f[0]=='R' and int(f[5])==1:
            branches.append((int(f[3],16),int(f[4],16),bool(int(f[6]))))
    candidates=[(name,ScaledTage(**geometry)) for name,geometry in GEOMETRIES.items()]
    candidates += [(f'NSL-{entries}',ScaledTage(entries=entries,sc=True,loop=True)) for entries in (8,16,32)]
    candidates += [(f'gshare{entries}-h{history}',Hybrid('gshare',entries,history))
                   for entries in (16,64,256) for history in (2,4,6,8) if history<=entries.bit_length()-1]
    for name,model in candidates:
        counts=collections.Counter();learning=[]
        for pc,target,taken in branches:
            query=model.lookup(pc)
            if isinstance(model,Hybrid):prediction=query.prediction
            else:
                prediction=query['prediction'];tage=query['tage']
                sc_enabled=model.sc_enabled and abs(query['sum'])>=model.threshold
                sc=(query['sum']>=0) if sc_enabled else tage
                if sc!=tage:
                    counts['sc_helpful' if sc==taken else 'sc_harmful']+=1
                loop=query['loop_prediction']
                if loop is not None and loop!=sc:
                    counts['loop_helpful' if loop==taken else 'loop_harmful']+=1
                counts['provider_base' if query['provider']<0 else 'provider_tagged']+=1
                counts['weak_provider']+=query['provider']>=0 and query['weak']
            counts['branches']+=1;counts['errors']+=prediction!=taken
            model.train(query,taken)
            if counts['branches']%4096==0:learning.append([counts['branches'],counts['errors']])
        records.append({'case':path.stem,'candidate':name,'geometry':GEOMETRIES.get(name),
                        'bits':model.bits,'scope':'M0 ROI cold; decoded identity; immediate resolved history',
                        'counts':dict(counts),'learning':learning})
    print('PASS M0 geometry',path.stem,flush=True)
(NPC/'docs/research/branch-v3/geometry-screen.json').write_text(json.dumps(records,indent=2)+'\n')
