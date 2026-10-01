#!/usr/bin/env python3
"""Separate local history from Gshare and TAGE; finite resources, M0 only."""
import json
from pathlib import Path
from models import LocalHistory
NPC=Path(__file__).resolve().parents[2]
records=[]
for path in sorted((NPC/'result/branch-v3/rtl/B0').glob('*.events')):
    branches=[]
    for line in path.open():
        row=line.strip().split(',')
        if row[0]=='R' and int(row[5])==1:branches.append((int(row[3],16),bool(int(row[6]))))
    for entries in (16,32,128):
        for history in (2,3,4):
            model=LocalHistory(entries,history);errors=0
            for pc,taken in branches:
                query=model.lookup(pc);errors+=query['prediction']!=taken;model.train(query,taken)
            records.append({'case':path.stem,'entries':entries,'history_bits':history,
                            'bits':model.bits,'errors':errors,'branches':len(branches),
                            'scope':'M0 cold decoded branches; immediate training; not CVA6S+ RTL'})
    print('PASS local M0',path.stem,flush=True)
(NPC/'docs/research/branch-v3/local-screen.json').write_text(json.dumps(records,indent=2)+'\n')
