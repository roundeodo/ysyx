#!/usr/bin/env python3
"""Run the frozen direction/history study without modifying stable defaults."""
import argparse,json
from pathlib import Path
from types import SimpleNamespace
import explore_frontend as experiment
from followup_branch import defines
from select_icache_ppa import qualify
from buffer_history_training import PARENTS, run as qualify_buffered


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['build','run','ppa'])
    p.add_argument('--root',type=Path,required=True);p.add_argument('--config',required=True)
    p.add_argument('--label',default='dev-common');p.add_argument('--mhz',type=int,default=720)
    p.add_argument('--held',action='store_true');p.add_argument('--random-stalls',action='store_true')
    p.add_argument('--trace',action='store_true');p.add_argument('--no-observer',action='store_true')
    p.add_argument('--latency-ns',type=int,default=100);p.add_argument('--beat-ns',type=int,default=10)
    p.add_argument('--resume',action='store_true')
    a=p.parse_args();root=a.root.resolve();c=json.loads((root/'configurations.json').read_text())[a.config]
    source=root/('baseline' if a.config=='B0' else 'candidate-source')
    build_map=json.loads((root/'build-map.json').read_text()) if (root/'build-map.json').exists() else {}
    build=root/'builds'/build_map.get(a.config,a.config)
    if a.action=='build':
        experiment.TEST=source/'npc/tests/frontend_exploration'
        experiment.build_rtl(build,source/'npc/vsrc/riscv32',defines(c),host_opt=2)
        (build/'config.json').write_text(json.dumps(c,indent=2)+'\n')
    elif a.action=='ppa':
        if a.config in PARENTS:
            qualify_buffered(root,a.config)
            return
        qualify(a.config,root/'ppa',a.resume,cache_config=(1024,4,13,32),
                extra_make=[x.replace('YSYX_','NPC_',1) for x in defines(c)],source_root=source)
    else:
        assert json.loads((build/'config.json').read_text())==c
        if a.held: assert (root/'selection-freeze.json').exists()
        experiment.simulate(SimpleNamespace(output=root/'rtl'/a.label/a.config,images=root/'images',
            binary=build/'obj/Vexploration_core_tb',mhz=a.mhz,held_out=a.held,latency_ns=a.latency_ns,
            beat_ns=a.beat_ns,random_stalls=a.random_stalls,no_observer=a.no_observer,
            no_trace=not a.trace,memory_mode='physical'))

if __name__=='__main__':main()
