#!/usr/bin/env python3
"""Run existing RV32 CPU programs against NEMU; never change its active configuration."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from explore_frontend import NPC,sha
from followup_branch import defines
from compact_target_artifacts import prune_objects


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    p.add_argument('--configs',nargs='+',required=True)
    p.add_argument('--target-study',action='store_true')
    p.add_argument('--resume',action='store_true')
    a=p.parse_args();root=a.root.resolve()
    selected_defines=defines
    if a.target_study:
        from explore_target_storage import defines as selected_defines
    configs=json.loads((root/'configurations.json').read_text())
    env=dict(os.environ,NPC_HOME=str(NPC),AM_HOME=str(NPC.parent/'abstract-machine'),NEMU_HOME=str(NPC.parent/'nemu'))
    reference=NPC.parent/'nemu/build/riscv32-nemu-interpreter-so';assert reference.exists()
    capstone=NPC.parent/'nemu/tools/capstone/repo'
    if not (capstone/'libcapstone.a').exists():capstone=NPC.parent.parent/'ysyx-workbench/nemu/tools/capstone/repo'
    assert (capstone/'libcapstone.a').exists()
    tests=['add','shift','load-store','if-else','recursion','quick-sort','select-sort','bubble-sort','string','switch']
    folder=root/'difftest';folder.mkdir(exist_ok=a.resume);images=folder/'images';images.mkdir(exist_ok=a.resume)
    for name in tests:
        source=NPC.parent/'am-kernels/tests/cpu-tests/build'/f'{name}-riscv32-npc.bin'
        assert source.exists(),source
        if (images/source.name).exists():assert sha(source)==sha(images/source.name)
        else:shutil.copy2(source,images/source.name)
    provenance={'reference':str(reference),'reference_sha256':sha(reference),
                'images':{p.name:sha(p) for p in images.iterdir()},'configs':configs,'records':[]}
    if (folder/'results.json').exists():
        previous=json.loads((folder/'results.json').read_text())
        for key in ['reference','reference_sha256','images']:assert previous[key]==provenance[key]
        # Adding a new independent configuration must not invalidate completed
        # cases, but changing any previously bound configuration still does.
        for name,config in previous['configs'].items():
            assert provenance['configs'].get(name)==config,name
        previous['configs']=configs
        provenance=previous
    for name in a.configs:
        prior=[r for r in provenance['records'] if r['config']==name]
        if prior:
            assert len(prior)==len(tests) and {r['test'] for r in prior}==set(tests)
            for r in prior:assert sha(Path(r['command'][0]))==r['binary_sha256']
            continue
        out=folder/name;out.mkdir()
        command=['make','-C',str(NPC),'git_commit=','NPC_CONFIG=rv32-baseline','build-npc',
                 f'BUILD_DIR={out/"build"}',f'CAPSTONE_HOME={capstone}',
                 *[d.replace('YSYX_','NPC_',1) for d in selected_defines(configs[name])]]
        with (out/'build.log').open('w') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,env=env)
        binaries=list((out/'build').glob('*_sim'));assert len(binaries)==1,binaries
        binary=binaries[0]
        for test in tests:
            run=[str(binary),'--batch','--diff',str(reference),str(images/f'{test}-riscv32-npc.bin')]
            with (out/(test+'.log')).open('w') as log:subprocess.run(run,stdout=log,stderr=subprocess.STDOUT,check=True,env=env)
            text=(out/(test+'.log')).read_text();assert 'HIT GOOD TRAP' in text,(name,test,text[-1000:])
            provenance['records'].append({'config':name,'test':test,'build_command':command,'command':run,'binary_sha256':sha(binary)})
            (folder/'results.json').write_text(json.dumps(provenance,indent=2)+'\n')
            print('PASS NEMU',name,test,flush=True)
        if a.target_study:
            prune_objects(out / 'build')


if __name__=='__main__':main()
