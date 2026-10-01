#!/usr/bin/env python3
"""Mixed-FU overlap and age recovery checked against NEMU and software results."""
import argparse
import hashlib
import json
import re
import resource
from pathlib import Path
from test_muldiv import NPC, run
from test_muldiv_core import image


def mixed_program():
    code = ['li s0,0x800f0000', 'li t0,0x76543210', 'li t1,17',
            'li t2,123', 'li t3,45', 'sw t2,0(s0)', 'li s1,128', 'loop:']
    code += ['divu a1,t0,t1', 'mul a2,t2,t3', 'add a3,t2,t3', 'lw a4,0(s0)',
             'li t4,0x06f5e4d3', 'bne a1,t4,fail', 'li t4,5535', 'bne a2,t4,fail',
             'li t4,168', 'bne a3,t4,fail', 'bne a4,t2,fail', 'addi s1,s1,-1', 'bnez s1,loop']
    code += ['divu a1,t0,t1', 'remu a2,t0,t1', 'divu a3,t0,zero', 'remu a4,t0,zero',
             'li t4,0x06f5e4d3','bne a1,t4,fail','li t4,13','bne a2,t4,fail',
             'li t4,-1','bne a3,t4,fail','bne a4,t0,fail']
    # Multiple versions of one architectural register finish out of order.
    # The consumer must use the youngest multiply, never the completed add or old divide.
    code += ['divu a5,t0,t1','addi a5,zero,77','mul a5,t2,t3','addi a6,a5,1',
             'li t4,5536','bne a6,t4,fail','li t4,5535','bne a5,t4,fail']
    # The branch resolves before the older divide; its result must survive.
    code += ['sw zero,4(s0)', 'li s2,0','divu a1,t0,t1','beq t2,t2,target',
             'mul s2,t2,t3','sw t2,4(s0)','target:', 'lw t4,4(s0)', 'bnez t4,fail',
             'bnez s2,fail','li t4,0x06f5e4d3','bne a1,t4,fail',
             'li a0,0','ebreak','fail:','li a0,1','ebreak']
    return '\n'.join(code)


def issue_context_program():
    # Following Decode fields differ from the CSR held in Issue. The divider
    # also forces a serializing CSR to wait while preserving its identity.
    return """
      li s0,0x12345678
      li s1,0x80000100
      csrw mscratch,s0
      csrr t2,mscratch
      addi t3,zero,37
      bne t2,s0,fail
      li t0,0x76543210
      li t1,17
      divu a1,t0,t1
      csrr t2,mscratch
      csrw mtvec,s1
      csrr t3,mtvec
      csrrw t4,mscratch,s1
      csrr t5,mscratch
      bne t2,s0,fail
      bne t3,s1,fail
      bne t4,s0,fail
      bne t5,s1,fail
      li t0,0x06f5e4d3
      bne a1,t0,fail
      li a0,0
      ebreak
    fail:
      li a0,1
      ebreak
    """


def multiply_burst_program():
    code = ['li t0,123', 'li t1,45', 'li s0,64', 'loop:']
    code += [f'mul a{i},t0,t1' for i in range(1, 7)]
    code += ['li t2,5535'] + [f'bne a{i},t2,fail' for i in range(1, 7)]
    code += ['addi s0,s0,-1', 'bnez s0,loop', 'li a0,0', 'ebreak',
             'fail:', 'li a0,1', 'ebreak']
    return '\n'.join(code)


def load_overlap_program():
    # Distinct cold lines make a younger multiply overlap an outstanding load.
    code = ['la s0,cold_data', 'li s1,32', 'li t0,123', 'li t1,45', 'loop:',
            'lw a1,0(s0)', 'mul a2,t0,t1', 'addi a3,a2,1', 'li t2,0x13579',
            'bne a1,t2,fail', 'li t2,5536',
            'bne a3,t2,fail', 'addi s0,s0,64', 'addi s1,s1,-1', 'bnez s1,loop',
            'li a0,0', 'ebreak', 'fail:', 'li a0,1', 'ebreak',
            '.balign 64', 'cold_data:', '.rept 32', '.word 0x13579', '.zero 60', '.endr']
    return '\n'.join(code)


def dependent_program():
    # The dependency chain cannot benefit from executing independent FUs.
    return """
      li t0,1
      li t1,3
      li s0,64
    loop:
      mul t0,t0,t1
      divu t0,t0,t1
      addi s0,s0,-1
      bnez s0,loop
      li t2,1
      bne t0,t2,fail
      li a0,0
      ebreak
    fail:
      li a0,1
      ebreak
    """



def alu_chain_program():
    # Hot dependent integer stream: Execute-to-Issue forwarding must sustain one ALU per cycle.
    code = ['li t0,0', 'li s0,64', 'loop:']
    code += ['addi t0,t0,1'] * 16
    code += ['addi s0,s0,-1', 'bnez s0,loop', 'li t1,1024', 'bne t0,t1,fail',
             'li a0,0', 'ebreak', 'fail:', 'li a0,1', 'ebreak']
    return '\n'.join(code)


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-overlap', action='store_true')
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    cases = [('mixed', mixed_program()), ('issue-context', issue_context_program()),
             ('multiply-burst', multiply_burst_program()),
             ('load-overlap', load_overlap_program()), ('dependent', dependent_program()),
             ('alu-chain', alu_chain_program())]
    records = {}
    counters = {}
    for name, assembly in cases:
        binary = image(out, name, assembly)
        command = [str(args.simulator.resolve()), '--batch']
        # This NEMU build aborts on mscratch (0x340). Keep the complete CSR
        # test and its software oracle; other programs still use DiffTest.
        difftest = name != 'issue-context'
        if difftest:
            command += ['--diff', str(NPC.parent/'nemu/build/riscv32-nemu-interpreter-so')]
        command.append(str(binary))
        run(command, out / (name + '.log'))
        text = (out / (name + '.log')).read_text()
        assert 'HIT GOOD TRAP' in text, name
        lines = [line for line in text.splitlines() if line.startswith(('NPC ROB:', 'NPC FU:'))]
        record = {'command': command, 'difftest': difftest, 'software_oracle': True, 'image_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'cycles': int(re.search(r'CPU cycle\s*=\s*(\d+)', text)[1]),
                  'retired': int(re.search(r'retired instructions\s*=\s*(\d+)', text)[1]),
                  'backend_counters': lines}
        records[name] = record
        for line in lines:
            if line.startswith('NPC FU:'):
                for key, value in re.findall(r'(\w+)=(\d+)', line):
                    counters[key] = counters.get(key, 0) + int(value)
        print(name, record, flush=True)
    if args.require_overlap:
        for key in ['mul_during_div', 'load_during_div', 'mul_during_load',
                    'consecutive_mul', 'out_of_order_completions']:
            assert counters.get(key, 0) > 0, (key, counters)
    # Retain the original mixed-program fields for existing result consumers.
    report = dict(records['mixed'], cases=records, fu_counters=counters,
                  overlap_required=args.require_overlap,
                  simulator_sha256=hashlib.sha256(args.simulator.read_bytes()).hexdigest())
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__=='__main__': main()
