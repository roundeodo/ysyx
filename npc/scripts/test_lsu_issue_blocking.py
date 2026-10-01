#!/usr/bin/env python3
"""Whole-core RTL comparison of equivalent schedules around a second load.

Moving independent arithmetic before the blocked second load exposes existing
FU overlap. This diagnoses head-of-line blocking; it is not a multi-load LSU.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
from test_muldiv import NPC, run
from test_muldiv_core import image


def program(kind, schedule):
    code = ['la s0,data', 'la s2,hot', 'li s1,32', 'li t0,0x76543210', 'li t1,17',
            'li t2,123', 'li t3,45', 'lw t6,0(s2)', 'addi t6,t6,0', 'loop:']
    second = {'same-line': 'lw a2,4(s0)', 'other-hit': 'lw a2,0(s2)',
              'other-miss': 'lw a2,16(s0)', 'both-hit': 'lw a2,0(s2)'}[kind]
    operations = ['lw a1,0(s0)', second, 'divu a3,t0,t1', 'mul a4,t2,t3']
    if schedule == 'arithmetic-first': operations = [operations[i] for i in (0, 2, 3, 1)]
    code += operations
    code += ['li t4,0x13579', 'bne a1,t4,fail', 'bne a2,t4,fail',
             'li t4,0x06f5e4d3', 'bne a3,t4,fail', 'li t4,5535', 'bne a4,t4,fail',
             f'addi s0,s0,{0 if kind == "both-hit" else 64}', 'addi s1,s1,-1', 'bnez s1,loop',
             'li a0,0', 'ebreak', 'fail:', 'li a0,1', 'ebreak',
             '.balign 64', 'data:', '.rept 32', '.word 0x13579', '.word 0x13579',
             '.zero 8', '.word 0x13579', '.zero 44', '.endr',
             '.balign 64', '.zero 32', 'hot:', '.word 0x13579']
    return '\n'.join(code)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', type=Path, required=True)
    parser.add_argument('--legacy', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--without-probe', action='store_true',
                        help='Compare functional RTL cycles without the optional stall observer')
    args=parser.parse_args(); output=args.output.resolve(); output.mkdir(parents=True,exist_ok=False)
    results={}
    for kind in ('same-line','other-hit','other-miss','both-hit'):
        results[kind]={}
        for schedule in ('loads-first','arithmetic-first'):
            name=f'{kind}-{schedule}'
            binary=image(output,name,program(kind,schedule))
            for variant, simulator in [('rob',args.simulator),('legacy',args.legacy)]:
                if simulator is None: continue
                key=f'{name}-{variant}'
                command=[str(simulator.resolve()),'--batch','--diff',str(NPC.parent/'nemu/build/riscv32-nemu-interpreter-so'),str(binary)]
                if variant=='rob' and not args.without_probe: command.append(f'+NPC_STALL_OUTPUT={output}/{key}.jsonl')
                run(command,output/f'{key}.log')
                log=(output/f'{key}.log').read_text(); assert 'HIT GOOD TRAP' in log, key
                record={'cycles':int(re.search(r'CPU cycle\s*=\s*(\d+)',log)[1]),
                        'retired':int(re.search(r'retired instructions\s*=\s*(\d+)',log)[1]),
                        'command':command,'image_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
                if variant=='rob' and not args.without_probe:
                    rows=[json.loads(s) for s in (output/f'{key}.jsonl').read_text().splitlines()]
                    record['observation']=next(r for r in rows if r['type']=='finish')
                    assert sum(record['observation']['categories'].values())==record['observation']['cycles']
                results[kind][f'{variant}-{schedule}']=record
                print(key,record['cycles'],record['retired'],flush=True)
        for variant in ('rob','legacy'):
            if f'{variant}-loads-first' in results[kind]:
                assert results[kind][f'{variant}-loads-first']['retired']==results[kind][f'{variant}-arithmetic-first']['retired']
    (output/'report.json').write_text(json.dumps({'cases':results,'scope':'same work, equal retired instruction counts, different software schedule; standalone RTL with NEMU; not native SoC time'},indent=2)+'\n')


if __name__=='__main__': main()
