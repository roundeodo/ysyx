#!/usr/bin/env python3
"""Independent Python table/snapshot reference versus cycle-accurate BHT RTL."""
import argparse,hashlib,json,random,subprocess
from pathlib import Path
from model_history import SmallTage
from explore_frontend import NPC
from followup_branch import defines


def vectors(path, entries, policy):
    rng=random.Random(91024);model=SmallTage(entries,protect_alternate=policy==4);pending=[]
    coverage=dict(invalidate=0,reset=0,delayed_training=0,stale_provider=0)
    with path.open('w') as f:
        for cycle in range(30000):
            reset=cycle in [8003,19003]
            invalidate=cycle%937==13
            if reset: model=SmallTage(entries,protect_alternate=policy==4);pending=[];coverage['reset']+=1
            pc=0x100+4*rng.randrange(192)
            # Repeated streams plus aliases, not only independent random queries.
            if cycle%97<64:pc=0x100+4*(cycle%8)
            query=model.lookup(pc)
            training=pending.pop(0) if pending and (len(pending)>8 or rng.randrange(4)!=0) else None
            context,taken=training if training else (dict(pc=0,history=0,provider=0,alternate_provider=0,taken=False,alternate=False),False)
            fields=[int(reset),int(invalidate),f'{pc:x}',f'{model.history:x}',int(query['taken']),query['provider'],query['alternate_provider'] if policy==4 else 0,int(query['alternate']),int(training is not None),f'{context["pc"]:x}',f'{context["history"]:x}',context['provider'],context['alternate_provider'] if policy==4 else 0,int(context['taken']),int(context['alternate']),int(taken)]
            f.write(' '.join(map(str,fields))+'\n')
            if rng.randrange(11)==0:pending.clear() # flush drops younger snapshots; does not clear tables
            if not reset and rng.randrange(4)!=0:
                pending.append((query,bool(((pc>>2)^cycle^(cycle>>3))&1)))
            if reset: continue
            if invalidate:
                model.history=0;model.banks=[[None]*entries for _ in range(3)];pending=[];coverage['invalidate']+=1
            elif training:
                model.train(context,taken);coverage['delayed_training']+=1
                coverage['stale_provider']+=model.stats.pop('stale_provider',0)
    assert coverage['stale_provider']>0,coverage
    return coverage


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--case',nargs=2,type=int,metavar=('ENTRIES','POLICY'),help='Run one additional parameter case')
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    rtl=NPC/'vsrc/riscv32';files=[rtl/'common'/n for n in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_pkg.sv']]
    files += [rtl/'core/frontend/riscv32_tage.sv',rtl/'core/frontend/riscv32_bht.sv',NPC/'tests/rtl/riscv32_tage_contract_tb.sv']
    results=[]
    cases=[tuple(a.case)] if a.case else [(8,3),(16,3),(16,4),(32,3),(32,4)]
    assert all(n in [8,16,32] and policy in [3,4] for n,policy in cases)
    for entries,policy in cases:
        directory=out/f'n{entries}-p{policy}';directory.mkdir();path=directory/'vectors.txt'
        coverage=vectors(path,entries,policy)
        command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',
                 '+define+YSYX_RV32_BASELINE', '+define+YSYX_DCACHE_ENABLE=1',
                 '+define+YSYX_DCACHE_CAPACITY_BYTES=256', '+define+YSYX_DCACHE_WAY_COUNT=2',
                 '+define+YSYX_DCACHE_LINE_BYTES=16',
                 *['+define+'+v for v in defines(dict(bht=entries,direction_policy=policy,history_bits=16))],
                 '--top-module','riscv32_tage_contract_tb','--Mdir',str(directory/'obj'),*map(str,files)]
        for cmd,log in [(command,'build.log'),([str(directory/'obj/Vriscv32_tage_contract_tb'),f'+vectors={path}'],'run.log')]:
            with (directory/log).open('w') as stream:subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,check=True)
        result=(directory/'run.log').read_text();assert 'PASS TAGE' in result
        results.append(dict(entries=entries,policy=policy,coverage=coverage,command=command,result=result))
        (out/'results.json').write_text(json.dumps(dict(results=results,sources={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}),indent=2)+'\n')
        print(result.strip(),flush=True)

if __name__=='__main__':main()
