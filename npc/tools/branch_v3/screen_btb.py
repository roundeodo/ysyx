#!/usr/bin/env python3
"""M1 BTB sweep at actual query/resolve times; never reports CPU speedup."""
import csv, hashlib, json, struct, subprocess
from pathlib import Path
from trace_io import event_files, open_text, sha_uncompressed
NPC=Path(__file__).resolve().parents[2]
ROOT=NPC/'result/branch-v3'
OUT=ROOT/'btb-screen'

def main():
    OUT.mkdir(exist_ok=False)
    tool=Path(__file__).resolve().parent
    command=['g++','-std=c++17','-O3',str(tool/'screen_btb.cpp'),'-o',str(OUT/'screen')]
    subprocess.run(command,check=True)
    records=[]
    for directory in ['B0-victim-dev','B0-victim-stream-dev-700']:
        for path in event_files(ROOT/'rtl'/directory):
            instructions={};roi={}
            with open_text(path) as stream:
                for line in stream:
                    row=line.rstrip().split(',')
                    if row[0]=='C':instructions[int(row[3],16)]=int(row[4],16)
                    elif row[0]=='R':roi[int(row[1])]=row
            assert all((inst & 0x707f) != 0x100f for inst in instructions.values()), 'FENCE.I needs explicit invalidation events'
            binary=OUT/(path.stem+'.bin');queries=0
            with binary.open('xb') as out,open_text(path) as stream:
                for line in stream:
                    row=line.rstrip().split(',')
                    if row[0]=='Q':
                        r=roi.get(int(row[1]));queries+=1
                        event=[0,int(row[3],16),int(r[4],16) if r else 0,int(r[5])-1 if r else 0,int(r[6]) if r else 0,int(r is not None),int(row[4]),int(row[8],16),int(row[7])]
                    elif row[0]=='F':
                        pc=int(row[3],16);inst=instructions[pc];kind=int(row[5])-1
                        rd=(inst>>7)&31;rs1=(inst>>15)&31
                        if kind==2 and rs1 in (1,5) and (rd not in (1,5) or rd!=rs1) and (inst>>20)==0:kind=3
                        event=[1,pc,int(row[4],16),kind,int(row[6]),0,0,0,0]
                    else:continue
                    out.write(struct.pack('<9I',*event))
            result=subprocess.run([str(OUT/'screen'),str(binary)],check=True,capture_output=True,text=True)
            columns='entries ways index policy admission queries taken absent wrong cold pending unadmitted fa_hit fa_miss'.split()
            rows=[dict(zip(columns,map(int,row))) for row in csv.reader(result.stdout.splitlines())]
            records.append({'case':path.stem,'event_path':str(path.relative_to(NPC)),
                            'event_sha256':sha_uncompressed(path),'full_query_checks':queries,'rows':rows})
            (OUT/(path.stem+'.csv')).write_text(','.join(columns)+'\n'+result.stdout)
            print('PASS BTB M1 baseline exact',path.stem,queries,'queries;',len(rows),'candidates',flush=True)
    doc={'scope':'Full-prefix baseline query/resolve order. ROI scoring. 120 fixed candidates; no train or holdout.',
         'limits':['Candidate does not regenerate wrong paths or query timing; no CPU speed estimate.',
                   'fa_hit/fa_miss compare same-capacity fully associative LRU with the same admission; not exact conflict/capacity attribution for every replacement.',
                   'wrong compares stored last target; does not apply RAS override.',
                   'cold means no earlier query or resolution; pending means previously queried but never resolved, including cancelled queries.'],
         'command':command,'sources':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [tool/'btb_model.h',tool/'screen_btb.cpp',Path(__file__)]},'records':records}
    (NPC/'docs/research/branch-v3/btb-screen.json').write_text(json.dumps(doc,indent=2)+'\n')
if __name__=='__main__':main()
