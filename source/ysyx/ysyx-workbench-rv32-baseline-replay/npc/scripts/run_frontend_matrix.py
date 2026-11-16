#!/usr/bin/env python3
"""Small serial experiment matrix. Held-out runs require a pre-existing freeze record."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

NPC = Path(__file__).resolve().parents[1]
CONFIGS = {'B0': (256,1,0,16), 'B1': (256,2,0,16), 'B2': (256,2,1,16),
           'B3': (256,2,2,16), 'C': (256,2,3,16), 'capacity': (512,1,0,16),
           'line32': (256,1,0,32)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--phase',choices=['dev','held'],required=True)
    parser.add_argument('--configs',nargs='+',choices=list(CONFIGS),default=list(CONFIGS))
    parser.add_argument('--mhz',type=int,default=580)
    parser.add_argument('--latency-ns',type=int,default=100)
    parser.add_argument('--beat-ns',type=int,default=10)
    parser.add_argument('--random-stalls',action='store_true')
    args=parser.parse_args();root=args.root.resolve()
    if args.phase=='held':
        freeze=json.loads((root/'selection-freeze.json').read_text())
        assert freeze['configs']=={k:list(v) for k,v in CONFIGS.items()}
        for name,digest in freeze['source_hashes'].items():
            assert hashlib.sha256((NPC/name).read_bytes()).hexdigest()==digest,name
    for name in args.configs:
        capacity,ways,policy,line=CONFIGS[name]
        build=root/'final-builds'/name
        if not build.exists():
            command=['python3',str(NPC/'scripts/explore_frontend.py'),'build','--output',str(build)]
            for key,value in [('CAPACITY_BYTES',capacity),('WAY_COUNT',ways),('REPLACEMENT_POLICY',policy),('LINE_BYTES',line)]:
                command+=['--define',f'YSYX_ICACHE_{key}={value}']
            subprocess.run(command,check=True)
        manifest=json.loads((build/'manifest.json').read_text())
        for path,digest in manifest['sources'].items():
            assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest,path
        output=root/'final-results'/f'{args.phase}-{name}-{args.mhz}-{args.latency_ns}-{args.beat_ns}-{int(args.random_stalls)}'
        command=['python3',str(NPC/'scripts/explore_frontend.py'),'run','--images',str(root/'images-v2'),
                 '--binary',str(build/'obj/Vexploration_core_tb'),'--output',str(output),'--mhz',str(args.mhz),
                 '--latency-ns',str(args.latency_ns),'--beat-ns',str(args.beat_ns)]
        if args.phase=='held':command+=['--held-out']
        if args.random_stalls:command+=['--random-stalls']
        subprocess.run(command,check=True)


if __name__=='__main__':main()
