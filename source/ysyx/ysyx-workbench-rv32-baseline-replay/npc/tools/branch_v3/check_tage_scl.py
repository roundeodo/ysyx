#!/usr/bin/env python3
"""Compare every query context and post-edge logical state, including folded history."""
import json,random,subprocess
from pathlib import Path
from models import ScaledTage,fold
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3/tage-scl'
if __name__ == '__main__' and (ROOT/'results.json').exists():
    import time
    ROOT=ROOT.with_name('tage-scl-check-'+time.strftime('%H%M%S'))
ROOT.mkdir(parents=True,exist_ok=True)

def pack_context(q):
    base, entries, lengths, tag_bits = q.get('layout', (32,16,(3,7,16),8))
    index_bits = entries.bit_length()-1
    packed = lambda values,width: sum(x<<(b*width) for b,x in enumerate(values))
    fields=[(q.get('history_before',0),max(lengths)),(q['pc'],32),(q['epoch'],16),
            (packed(q['indices'],index_bits),len(lengths)*index_bits),
            (packed(q['tags'],tag_bits),len(lengths)*tag_bits),
            (q['base'],base.bit_length()-1),(q['provider'],3),(q['alt'],1),(q['raw'],1),
            (q['weak'],1),(q['tage'],1),
            (packed(q['sc_indices'],index_bits),3*index_bits),(q['sum'],9),
            (q['loop'],2),(q['prediction'],1)]
    value=0
    for field,width in fields:value=(value<<width)|(int(field)&((1<<width)-1))
    return value

def pack_state(m):
    fields=[(x,2) for x in m.base]
    entry_bits=1+m.tag_bits+3+2
    for table in m.tables:
        for e in table:
            fields.append((0 if e is None else (1<<(entry_bits-1))|(e['tag']<<5)|((e['ctr']&7)<<2)|e['u'],entry_bits))
    fields.extend([(m.history,max(m.lengths)),(m.epoch,16),(m.alt_select,4)])
    fields.extend((w,5) for table in m.weights for w in table)
    fields.append((m.threshold,5))
    for e in m.loops:
        value=0 if e is None else (1<<51)|(e['pc']<<19)|(e['current']<<11)|(e['trip']<<3)|(e['confidence']<<1)|int(e['direction'])
        fields.append((value,52))
    index_bits=m.entries.bit_length()-1
    for length in m.lengths:
        value=(fold(m.history,length,index_bits)<<(2*m.tag_bits-1)) | (fold(m.history,length,m.tag_bits)<<(m.tag_bits-1)) | fold(m.history,length,m.tag_bits-1)
        fields.append((value,index_bits+2*m.tag_bits-1))
    fields.append((getattr(m,'resolved_history',0),max(m.lengths)))
    value=0;offset=0
    for field,width in fields:value|=(field&((1<<width)-1))<<offset;offset+=width
    return value

if __name__ == '__main__':
    records=[]
    for sc,lp in [(0,0),(0,1),(1,0),(1,1)]:
        folder=ROOT/f'sc{sc}-loop{lp}';folder.mkdir(exist_ok=True)
        command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2','--top-module','tage_scl_tb',f'-GSC_ENABLE={sc}',f'-GLOOP_ENABLE={lp}','+define+BRANCH_V3_VERIFY','--Mdir',str(folder/'obj'),str(NPC/'vsrc/riscv32/core/frontend/riscv32_tage_scl.sv'),str(NPC/'tests/branch_v3/tage_scl_tb.sv')]
        with (folder/'build.log').open('w') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
        for seed in [101,202,303]:
            rng=random.Random(seed);m=ScaledTage(sc=bool(sc),loop=bool(lp));saved=[None]*64;expected=[];rows=[]
            for cycle in range(3000):
                slot=cycle%64;train_slot=(cycle-rng.randrange(1,33))%64
                pc=0x100 if cycle<300 else 0x100+4*rng.randrange(128)
                tv=saved[train_slot] is not None and rng.randrange(5)!=0
                tk=cycle%4!=3 if cycle<300 else bool(rng.randrange(2));iv=cycle in [301,302,999,1700]
                q=m.lookup(pc);prev=saved[train_slot]
                if iv:m.invalidate()
                elif tv:m.train(prev,tk)
                expected.append((int(q['prediction']),pack_context(q),pack_state(m)))
                saved[slot]=q;rows.append(f'{pc:x} {slot} {train_slot} {int(tv)} {int(tk)} {int(iv)}\n')
            vectors=folder/f'seed{seed}.txt';vectors.write_text(''.join(rows));actual=folder/f'seed{seed}.out'
            with (folder/f'seed{seed}.log').open('w') as log:
                subprocess.run([str(folder/'obj/Vtage_scl_tb'),f'+input={vectors}',f'+output={actual}'],stdout=log,stderr=subprocess.STDOUT,check=True)
            lines=actual.read_text().splitlines();assert len(lines)==len(expected)
            for i,(line,ref) in enumerate(zip(lines,expected)):
                fields=line.split();got=(int(fields[0]),int(fields[1],16),int(fields[2],16))
                if got!=ref:
                    (folder/'mismatch.json').write_text(json.dumps({'seed':seed,'step':i,'actual':list(map(hex,got)),'expected':list(map(hex,ref))},indent=2)+'\n')
                    raise AssertionError((sc,lp,seed,i))
            records.append({'sc':sc,'loop':lp,'seed':seed,'steps':len(lines),'status':'passed-full-query-context-and-logical-state'})
            print('PASS',sc,lp,seed,len(lines),flush=True)
    (ROOT/'results.json').write_text(json.dumps(records,indent=2)+'\n')
