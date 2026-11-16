#!/usr/bin/env python3
"""Verify the replay's supported hybrid, legacy and disabled predictor circuits."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
from result_workspace import ResultWorkspace

NPC = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=NPC/'result/verification/replay-predictor')
    args = parser.parse_args()
    env = dict(os.environ, NPC_HOME=str(NPC))
    command = ['make','-s','-n','-C',str(NPC),'git_commit=','NPC_CONFIG=rv32-baseline','lint-npc']
    dry = subprocess.check_output(command,env=env,text=True)
    defines = [word for word in shlex.split(dry.replace('\\\n',' ')) if word.startswith('+define+')]
    assert len(defines)==len(set(defines))
    rtl = NPC/'vsrc/riscv32'
    sources = [rtl/'common'/name for name in ('riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_pkg.sv')]
    sources += [rtl/'core/frontend'/f'riscv32_{name}.sv' for name in
                ('branch_choice','direct_target','bht','btb','ras','branch_predictor','ifu')]
    sources += [rtl/'core/execute/riscv32_exu.sv']
    specs = [('hybrid-model','riscv32_replay_predictor_tb',1,2,1,[None]),
             ('legacy-model','riscv32_replay_predictor_tb',1,0,0,[None]),
             ('hybrid-direct','riscv32_replay_direct_tb',1,2,1,[None]),
             ('early-contract','riscv32_replay_early_target_tb',1,2,1,[11,29,97,101,12347,90121]),
             ('disabled','riscv32_no_predictor_tb',0,2,1,[None])]
    results=[]
    with ResultWorkspace(NPC,args.output,'replay-predictor') as run:
        for label,top,enabled,static,early,seeds in specs:
            folder=run.root/label;folder.mkdir()
            replacements={'YSYX_BRANCH_PREDICTOR_ENABLE':enabled,'YSYX_BRANCH_STATIC_POLICY':static,'YSYX_BRANCH_EARLY_TARGET':early}
            macros=[d for d in defines if d.split('=')[0].removeprefix('+define+') not in replacements]
            macros += [f'+define+{k}={v}' for k,v in replacements.items()]
            tb=NPC/'tests/rtl'/f'{top}.sv'
            build=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',*macros,
                   '--top-module',top,'--Mdir',str(folder/'obj'),*map(str,sources),str(tb)]
            with (folder/'build.log').open('w') as stream:
                result=subprocess.run(build,env=env,stdout=stream,stderr=subprocess.STDOUT)
            if result.returncode:
                print((folder/'build.log').read_text()[-6000:]);result.check_returncode()
            for seed in seeds:
                cmd=[str(folder/'obj'/f'V{top}')]+([] if seed is None else [f'+seed={seed}'])
                log=folder/f'run-{seed}.log'
                with log.open('w') as stream:
                    result=subprocess.run(cmd,env=env,stdout=stream,stderr=subprocess.STDOUT)
                print(log.read_text().strip(),flush=True);result.check_returncode()
                results.append({'case':label,'seed':seed,'passed':True,'build':build,'run':cmd})
            sources_with_tb=sources+[tb]
            (folder/'manifest.json').write_text(json.dumps({'source_hashes':{str(p.relative_to(NPC)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources_with_tb},'build':build},indent=2)+'\n')
            shutil.rmtree(folder/'obj')
        (run.root/'summary.json').write_text(json.dumps({'passed':True,'defines_command':command,'cases':results},indent=2)+'\n')

if __name__=='__main__':
    main()
