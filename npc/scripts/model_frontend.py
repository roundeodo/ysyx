#!/usr/bin/env python3
"""Trace screening only: no claim of IPC, speculative traffic or prefetch timeliness."""
import argparse
from collections import OrderedDict
import json
from pathlib import Path


def simulate(lines, capacity, ways, policy):
    count = capacity // 16 // ways
    sets = [[] for _ in range(count)]
    misses = 0
    for step, line in enumerate(lines):
        entries = sets[line % count]
        hit = next((e for e in entries if e['line'] == line), None)
        if hit:
            hit['last'] = step
            if policy in ['srrip', 'brrip']: hit['rrpv'] = 0
            continue
        misses += 1
        if len(entries) == ways:
            if policy in ['srrip', 'brrip']:
                while max(e['rrpv'] for e in entries) < 3:
                    for e in entries: e['rrpv'] += 1
                victim = next(e for e in entries if e['rrpv'] == 3)
            else:
                victim = min(entries, key=lambda e: e['last'] if policy == 'lru' else e['inserted'])
            entries.remove(victim)
        entries.append({'line': line, 'last': step, 'inserted': step,
                        'rrpv': 3 if policy == 'brrip' and misses % 32 else 2})
    return misses


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--traces', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    records = []
    for path in sorted(a.traces.glob('*.trace')):
        lines = [int(row.split(',')[0], 16) // 16 for row in path.read_text().splitlines()]
        unique = len(set(lines))
        for capacity, ways in [(256,1),(256,2),(256,4),(320,4),(512,1),(512,2),(256,16)]:
            for policy in (['fifo'] if ways == 1 else ['fifo','lru','srrip','brrip']):
                records.append({'case':path.stem,'bytes':capacity,'ways':ways,'policy':policy,
                                'misses':simulate(lines,capacity,ways,policy),'accesses':len(lines),
                                'unique_lines':unique,'note':'256/16 fully associative is diagnostic only'})
    a.output.write_text(json.dumps(records,indent=2)+'\n')
    # Feed only hints that have retired by the current fetch timestamp. This uses
    # B0's schedule and immediate model fills, so it screens utility, not timing.
    feedback = []
    for path in sorted(a.traces.glob('*.trace')):
        retired = [(int(row.split(',')[3]), int(row.split(',')[0],16)//16)
                   for row in path.read_text().splitlines() if len(row.split(',')) == 4]
        if not retired: continue
        fetches = [(int(row.split(',')[0]),int(row.split(',')[1],16)//16)
                   for row in path.with_suffix('.fetch').read_text().splitlines()]
        for policy in ['srrip','insert3','retire']:
            sets = [[] for _ in range(8)]
            misses = evictions = unused = hint_misses = pos = 0
            for cycle,line in fetches:
                while pos < len(retired) and retired[pos][0] < cycle:
                    _,rline=retired[pos];pos+=1
                    hit=next((e for e in sets[rline%8] if e['line']==rline),None)
                    if hit:
                        hit['used']=True
                        if policy=='retire': hit['rrpv']=0
                    else: hint_misses+=1
                entries=sets[line%8]
                hit=next((e for e in entries if e['line']==line),None)
                if hit:
                    if policy!='retire' or hit['rrpv']<3:hit['rrpv']=0
                    continue
                misses+=1
                if len(entries)==2:
                    delta=3-max(e['rrpv'] for e in entries)
                    for e in entries:e['rrpv']+=delta
                    victim=next(e for e in entries if e['rrpv']==3)
                    evictions+=1;unused+=not victim['used'];entries.remove(victim)
                entries.append({'line':line,'rrpv':2 if policy=='srrip' else 3,'used':False})
            feedback.append({'case':path.stem,'policy':policy,'misses':misses,'evictions':evictions,
                             'unused_evictions':unused,'hint_misses':hint_misses})
    a.output.with_name(a.output.stem+'-feedback.json').write_text(json.dumps(feedback,indent=2)+'\n')


if __name__ == '__main__': main()
