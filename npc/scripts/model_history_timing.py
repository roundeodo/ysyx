#!/usr/bin/env python3
"""Diagnostic branch-event pipeline; perfect branch identity/correct-path PC supply.

Not CPU timing: no BTB, I-cache, wrong-path instructions or lookup bandwidth cost.
Resolved history, oracle prefix history and speculative history are separate axes.
Every mode discards and replays younger lookups after a misprediction.
Recovery has no extra CPU-cycle model; all modes use the same event schedule.
"""
import argparse,json
from collections import deque,Counter
from pathlib import Path
from model_history import SmallTage,read_trace


def evaluate(records, entries, delay, mode):
    model=SmallTage(entries);pending=deque();cursor=0;tick=0;spec=0;prefix=0;stats=Counter()
    while cursor<len(records) or pending:
        if pending and pending[0][0]<=tick:
            _,position,query,taken=pending.popleft()
            wrong=query['taken']!=taken
            stats['resolved']+=1;stats['errors']+=wrong
            model.train(query,taken)
            if wrong:
                stats['replayed_queries']+=len(pending)
                pending.clear();cursor=position+1;spec=model.history;prefix=model.history
        if cursor<len(records):
            pc,_,taken,target,_,_=records[cursor]
            history=model.history if mode=='resolved' else prefix if mode=='oracle-prefix' else spec
            query=model.lookup(pc,history)
            stats['history_differs_from_prefix']+=history!=prefix
            pending.append((tick+delay,cursor,query,taken))
            if mode=='speculative': spec=((spec<<1)|query['taken'])&65535
            # Prefix is diagnostic only. Rebuild on replay from resolved history
            # plus known younger trace outcomes; never fed to speculative mode.
            if mode=='speculative':
                prefix=model.history
                for _,_,_,actual in pending:prefix=((prefix<<1)|actual)&65535
            else:prefix=((prefix<<1)|taken)&65535
            cursor+=1;stats['queries']+=1
        tick+=1
    assert stats['resolved']==len(records)
    return dict(stats)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();out={}
    for case in json.loads((root/'images/manifest.json').read_text())['cases']:
        if case['held']:continue
        path=root/'rtl/dev-common/B0'/(case['name']+'.trace')
        if not path.exists():path=path.with_suffix('.trace.gz')
        records,_=read_trace(path)
        out[case['name']]={f'{mode}-d{delay}':evaluate(records,16,delay,mode)
          for delay in [1,2,4] for mode in ['resolved','oracle-prefix','speculative']}
        print('HISTORY',case['name'],flush=True)
        (root/'history-model.json').write_text(json.dumps(dict(scope=__doc__,cases=out),indent=2)+'\n')

if __name__=='__main__':main()
