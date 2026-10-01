#!/usr/bin/env python3
"""Replay actual CPU query/train contexts against independent Python state."""
import argparse,json
from pathlib import Path
from models import ScaledTage,SpeculativeTage
from check_tage_scl import pack_context,pack_state
p=argparse.ArgumentParser();p.add_argument('files',type=Path,nargs='+');p.add_argument('--sc',action='store_true');p.add_argument('--loop',action='store_true');p.add_argument('--spec',action='store_true');p.add_argument('--tage-base',type=int,default=32);p.add_argument('--tage-entries',type=int,default=16);p.add_argument('--tage-tags',type=int,default=8);p.add_argument('--tage-lengths',type=int,nargs='+',default=[3,7,16]);a=p.parse_args()
records=[]
for file in a.files:
    model=(SpeculativeTage if a.spec else ScaledTage)(sc=a.sc,loop=a.loop,base=a.tage_base,entries=a.tage_entries,tag_bits=a.tage_tags,lengths=a.tage_lengths);saved={};steps=0;trains=0
    stream=iter(file.open())
    for line in stream:
        fields=line.strip().split(',');assert fields[0]=='M'
        pc,context,tv,taken,tc,iv,counter=[int(x,16) for x in fields[1:8]]
        query=model.lookup(pc);ref=pack_context(query)
        assert ref==context,(file,steps,'query-context',hex(ref),hex(context))
        assert (counter>=2)==query['prediction'],(file,steps,'direction')
        saved[ref]=query
        if a.spec:
            accepted,conditional,prediction,flush=[int(x) for x in fields[8:]]
            if tv: assert tc in saved,(file,steps,'unseen training snapshot')
            model.advance(accepted,conditional,prediction,saved[tc] if tv else None,bool(taken),flush,iv)
            trains+=tv
        elif iv:model.invalidate()
        elif tv:
            assert tc in saved,(file,steps,'unseen training snapshot')
            model.train(saved[tc],bool(taken));trains+=1
        post=next(stream).strip().split(',');assert post[0]=='P'
        state=pack_state(model);assert int(post[1],16)==state,(file,steps,'post-state')
        steps+=1
    records.append({'file':str(file),'events':steps,'training':trains,'sc':a.sc,'loop':a.loop,'status':'passed'})
    print('PASS actual CPU contexts/state',file.name,steps,trains)
Path(str(a.files[0].parent/'model-check.json')).write_text(json.dumps(records,indent=2)+'\n')
