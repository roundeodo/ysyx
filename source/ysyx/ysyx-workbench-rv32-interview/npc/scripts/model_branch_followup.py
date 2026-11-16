#!/usr/bin/env python3
"""Screen history policies on development programs; never open held traces."""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
from model_branch import decode,evaluate
from model_direction import CounterTable,BiMode,working_sets


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root;out=root/'model';out.mkdir(exist_ok=False)
    config=json.loads((root/'configurations.json').read_text())
    names=['B0','B64','B128','G64','G128','M64']
    result={'scope':'cold retired-order screening, immediate training; not CPU execution time','cases':{},'traces':{},'summary':{}}
    groups={}
    for case in json.loads((root/'images/manifest.json').read_text())['cases']:
        if case['held']:continue
        path=root/'rtl/dev-common/B0'/(case['name']+'.trace');raw=path.read_bytes();records=[];count=0
        for line in raw.decode().splitlines():
            pc,insn,nxt,_=line.split(',');count+=1;r=decode(int(pc,16),int(insn,16),int(nxt,16))
            if r:records.append(r)
        rows={}
        for name in names:
            c=config[name];policy=c.get('direction_policy',0);entries=c['bht']
            direction=BiMode(entries,4) if policy==2 else CounterTable(entries,4 if policy==1 else 0,history_shift=int(math.log2(entries))-4 if policy==1 else 0)
            rows[name]=evaluate(records,count,dict(bht=entries,btb=16,ways=2,ras=4,policy='all'),direction)
        result['cases'][case['name']]={'rows':rows,'working_sets':working_sets(records)}
        result['traces'][case['name']]=hashlib.sha256(raw).hexdigest();groups[case['name']]=case['kind']
        print('MODEL',case['name'],{n:rows[n]['counts']['errors'] for n in names},flush=True)
    for name in names:
        family=defaultdict(list)
        for case,record in result['cases'].items():
            rows=record['rows'];family[groups[case]].append(rows[name]['counts']['errors']/rows['B0']['counts']['errors'])
        family_ratios={k:math.prod(v)**(1/len(v)) for k,v in family.items()}
        result['summary'][name]={'error_ratio_gm':math.prod(family_ratios.values())**(1/len(family_ratios)),'by_family':family_ratios}
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result['summary'],indent=2),flush=True)


if __name__=='__main__':main()
