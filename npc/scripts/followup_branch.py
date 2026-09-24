#!/usr/bin/env python3
"""Bounded branch followup runner; configurations, sources and inputs are frozen."""
import argparse
import json
from pathlib import Path
from types import SimpleNamespace
import explore_frontend as experiment


def defines(c):
    cache=c.get('icache',[1024,4,32,13])
    settings=dict(ICACHE_CAPACITY_BYTES=cache[0],ICACHE_WAY_COUNT=cache[1],ICACHE_LINE_BYTES=cache[2],ICACHE_REPLACEMENT_POLICY=cache[3],
                  BRANCH_HISTORY_ENTRY_COUNT=c.get('bht',16),BRANCH_TARGET_ENTRY_COUNT=c.get('btb',16),BRANCH_TARGET_WAY_COUNT=2,
                  BRANCH_TARGET_POLICY=c.get('target_policy',0),RETURN_STACK_ENTRY_COUNT=4,
                  BRANCH_DIRECTION_POLICY=c.get('direction_policy',0),BRANCH_GLOBAL_HISTORY_BITS=c.get('history_bits',4))
    return [f'YSYX_{k}={v}' for k,v in settings.items()]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['build','run'])
    p.add_argument('--root',type=Path,required=True);p.add_argument('--config',required=True)
    p.add_argument('--source-root',type=Path);p.add_argument('--mhz',type=int,default=660)
    p.add_argument('--label',default='dev-common');p.add_argument('--held',action='store_true')
    p.add_argument('--trace',action='store_true');p.add_argument('--random-stalls',action='store_true')
    p.add_argument('--no-observer',action='store_true');p.add_argument('--latency-ns',type=int,default=100)
    p.add_argument('--beat-ns',type=int,default=10)
    a=p.parse_args();root=a.root.resolve();c=json.loads((root/'configurations.json').read_text())[a.config]
    build=root/'builds'/a.config
    if a.action=='build':
        source=a.source_root.resolve()/'npc';experiment.TEST=source/'tests/frontend_exploration'
        experiment.build_rtl(build,source/'vsrc/riscv32',defines(c),host_opt=2)
        (build/'config.json').write_text(json.dumps(c,indent=2)+'\n')
    else:
        assert json.loads((build/'config.json').read_text())==c
        if a.held: assert (root/'selection-freeze.json').exists(),'Freeze choice before held execution'
        experiment.simulate(SimpleNamespace(output=root/'rtl'/a.label/a.config,images=root/'images',
            binary=build/'obj/Vexploration_core_tb',mhz=a.mhz,held_out=a.held,latency_ns=a.latency_ns,
            beat_ns=a.beat_ns,random_stalls=a.random_stalls,no_observer=a.no_observer,no_trace=not a.trace,memory_mode='physical'))


if __name__=='__main__':main()
