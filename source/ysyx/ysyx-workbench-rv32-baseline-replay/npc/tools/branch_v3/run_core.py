#!/usr/bin/env python3
"""Closed-loop RTL, fixed physical-ns service; this is not the native SoC model."""
import argparse,json,sys,shutil,fcntl
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import explore_frontend as e
from followup_branch import defines
NPC=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('action',choices=['build','run']);p.add_argument('--name',default='B0')
p.add_argument('--direction',type=int,default=0);p.add_argument('--btb',type=int,default=16)
p.add_argument('--btb-ways',type=int,default=2);p.add_argument('--btb-policy',type=int,default=0)
p.add_argument('--btb-index',type=int,default=0);p.add_argument('--btb-admission',type=int,default=0)
p.add_argument('--icache-bytes',type=int,default=1024);p.add_argument('--icache-ways',type=int,default=4)
p.add_argument('--icache-line',type=int,default=32);p.add_argument('--icache-policy',type=int,default=13)
p.add_argument('--ram-kib',type=int,default=128)
p.add_argument('--max-cycles',type=int,default=20000000);p.add_argument('--branch-window',type=int,default=0)
p.add_argument('--compact',action='store_true',help='Keep counters and checks without large event/commit trace files')
p.add_argument('--metadata-trace',action='store_true',help='Record passive I-cache word/tag writes for target models')
p.add_argument('--choice',type=int,default=0);p.add_argument('--early',type=int,default=0)
p.add_argument('--sc',type=int,default=0);p.add_argument('--loop',type=int,default=0)
p.add_argument('--spec',type=int,default=0)
p.add_argument('--early-ras',type=int,default=0)
p.add_argument('--bht',type=int,default=16);p.add_argument('--history',type=int,default=4)
p.add_argument('--tage-base',type=int,default=32);p.add_argument('--tage-entries',type=int,default=16)
p.add_argument('--tage-tags',type=int,default=8)
p.add_argument('--tage-lengths',type=int,nargs='+',default=[3,7,16])
p.add_argument('--seed',type=int,default=97531)
p.add_argument('--validation',action='store_true')
p.add_argument('--final',action='store_true', help='Only frozen candidates and final-partition inputs')
p.add_argument('--cosim',action='store_true');p.add_argument('--case',action='append')
p.add_argument('--mhz',type=int,default=700);p.add_argument('--latency-ns',type=int,default=100)
p.add_argument('--random-stalls',type=int,default=0);p.add_argument('--label')
p.add_argument('--images',type=Path);a=p.parse_args()
root=NPC/'result/branch-v3';build=root/'builds'/a.name
if a.action=='build':
    snapshot=root/'snapshots'/a.name;snapshot.mkdir(parents=True,exist_ok=False)
    shutil.copytree(NPC/'vsrc/riscv32',snapshot/'rtl')
    test=snapshot/'tests';test.mkdir()
    for file in ['core_tb.sv','axi_memory.sv']:shutil.copyfile(NPC/'tests/branch_v3'/file,test/file)
    e.TEST=test
    settings=defines({'icache':[a.icache_bytes,a.icache_ways,a.icache_line,a.icache_policy],'direction_policy':a.direction,'btb':a.btb,'btb_ways':a.btb_ways,'target_policy':a.btb_policy,'target_index':a.btb_index,'target_admission':a.btb_admission,'bht':a.bht,'history_bits':16 if a.direction in (3,4) else a.history})
    settings += [f'BRANCH_V3_RAM_BYTES={a.ram_kib*1024}']
    settings += [f'YSYX_BRANCH_EARLY_RAS={a.early_ras}',f'YSYX_BRANCH_SPEC_HISTORY={a.spec}',f'YSYX_BRANCH_STATIC_POLICY={a.choice}',f'YSYX_BRANCH_EARLY_TARGET={a.early}',f'YSYX_BRANCH_SC_ENABLE={a.sc}',f'YSYX_BRANCH_LOOP_ENABLE={a.loop}']
    assert len(a.tage_lengths) in (2,3)
    geometry={'BASE_ENTRIES':a.tage_base,'TAGGED_ENTRIES':a.tage_entries,'TAG_BITS':a.tage_tags,'TABLE_COUNT':len(a.tage_lengths)}
    geometry.update({f'HISTORY_BITS_{i}':value for i,value in enumerate(a.tage_lengths)})
    settings += [f'YSYX_BRANCH_TAGE_{key}={value}' for key,value in geometry.items()]
    if a.cosim:settings+=['BRANCH_V3_VERIFY=1']
    e.build_rtl(build,snapshot/'rtl',settings,host_opt=1)
else:
    if a.final:
        assert not a.validation
        freeze=json.loads((NPC/'docs/research/branch-v3/selection-freeze.json').read_text())
        approved=freeze['candidates'][a.name]
        assert e.sha(build/'obj/Vexploration_core_tb') == approved['binary_sha256']
        assert a.mhz in approved['mhz'], 'Frequency was not frozen before holdout'
    out=root/'rtl'/(a.label or a.name)
    images=(a.images or root/'images').resolve();manifest=json.loads((images/'manifest.json').read_text());results=[]
    # Multiple frequency queues may reach the same immutable run. Serialize them,
    # and only reuse a completed run with an identical invocation and executable.
    lock_directory=root/'run-locks';lock_directory.mkdir(exist_ok=True)
    run_lock=(lock_directory/(out.name+'.lock')).open('a')
    fcntl.flock(run_lock,fcntl.LOCK_EX)
    invocation={key:getattr(a,key) for key in ('name','cosim','validation','final','mhz','latency_ns','random_stalls','seed','case','max_cycles','branch_window','compact')}
    if a.metadata_trace: invocation['metadata_trace'] = True
    invocation.update(images=str(images),binary_sha256=e.sha(build/'obj/Vexploration_core_tb'))
    if (out/'index.json').exists():
        assert json.loads((out/'invocation.json').read_text())==invocation, 'Completed run has a different invocation'
        print('REUSE identical completed run',out.name);sys.exit(0)
    out.mkdir(parents=True,exist_ok=False)
    (out/'invocation.json').write_text(json.dumps(invocation,indent=2)+'\n')
    built=json.loads((build/'manifest.json').read_text())
    assert int(built['settings'].get('BRANCH_V3_RAM_BYTES',131072)) >= manifest.get('ram_bytes',131072), 'Image exceeds simulated RAM'
    assert a.final or (manifest.get('split') != 'final' and images.name != 'images-final'), 'Use frozen holdout runner'
    for c in manifest['cases']:
        if a.final:
            if manifest.get('split') != 'final':
                if not c['held']:continue
                assert c.get('seed') in (2467,2474)
        else:
            if c['held'] != a.validation:continue
            if c['held']:assert c.get('seed') in (2437,2442), 'Final holdout needs selection freeze'
        if a.case and c['name'] not in a.case:continue
        name=c['name'];image=images/name
        for f,h in c['hashes'].items():assert e.sha(image/f)==h
        data=(image/'image.bin').read_bytes();data+=b'\0'*(-len(data)%4)
        encoded=''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4))
        assert encoded==(image/'image.hex').read_text(),'HEX is not bound to frozen binary'
        command=[build/'obj/Vexploration_core_tb',f'+image={image/"image.hex"}',f'+begin_pc={c["begin_pc"]:x}',f'+end_pc={c["end_pc"]:x}',f'+expected={c["expected"]:x}',f'+cpu_mhz={a.mhz}',f'+latency_ns={a.latency_ns}','+beat_ns=10',f'+seed={a.seed}','+memory_mode=physical',f'+random_stalls={a.random_stalls}',f'+events={out/(name+".events")}',f'+trace={out/(name+".trace")}']
        command += [f'+max_cycles={a.max_cycles}',f'+branch_window={a.branch_window}']
        if a.compact:
            command=[arg for arg in command if not str(arg).startswith(('+events=', '+trace='))]
        if a.metadata_trace: command += [f'+metadata_trace={out/(name+".metadata")}']
        if a.cosim:command += [f'+model_events={out/(name+".model")}']
        e.run(command,out/(name+'.log'));text=(out/(name+'.log')).read_text();assert 'PASS proxy' in text
        results.append({'name':name,'command':list(map(str,command)),'binary_sha256':e.sha(build/'obj/Vexploration_core_tb'),'log_sha256':e.sha(out/(name+'.log'))})
        print('PASS',a.name,name,flush=True)
    assert results,'No requested inputs were run'
    (out/'index.json').write_text(json.dumps(results,indent=2)+'\n')
