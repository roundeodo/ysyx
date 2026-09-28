#!/usr/bin/env python3
"""Whole-core multiply overlap, nearest-producer forwarding and precise recovery."""
import argparse
import json
import re
from pathlib import Path
from test_muldiv import NPC, run
from test_muldiv_core import image

def program():
    a = ['li s0,0x800f0000','li t0,123','li t1,45','li s1,0','li s2,0','sw zero,4(s0)']
    # Enough hot independent operations to expose initiation interval in total cycles.
    a += ['li s3,128','burst:']
    for i in range(16):
        a += [f'mul {"a"+str(i%8)},t0,t1']
    a += ['addi s3,s3,-1','bnez s3,burst','li t4,5535']
    for i in range(8): a += [f'bne a{i},t4,fail']
    # Older multiplication, younger same-rd multiplication, then dependent ALU/store.
    a += ['mul t2,t0,t1','mul t2,t0,t0','addi t3,t2,1','li t4,15130','bne t3,t4,fail',
          'sw t2,0(s0)','lw t3,0(s0)','li t4,15129','bne t3,t4,fail']
    # A current ALU writer overrides both older pipeline producers with the same rd.
    a += ['mul t2,t0,t1','mul t3,t0,t0','addi t2,zero,77','addi t5,t2,1',
          'li t4,78','bne t5,t4,fail','li t4,15129','bne t3,t4,fail']
    # High-half signed operations, x0 and a multiply-to-divide dependency.
    a += ['li t0,0x80000001','li t1,0xfffffffe','mulh t2,t0,t1','mulhsu t3,t0,t1',
          'mulhu t4,t0,t1','mul zero,t0,t1','li t5,0','bne t2,t5,fail',
          'li t5,0x80000001','bne t3,t5,fail','li t5,0x7fffffff','bne t4,t5,fail',
          'li t0,123','li t1,45','mul t2,t0,t1','div t3,t2,t1','bne t3,t0,fail']
    # Older multiply must complete before a taken branch; younger work is canceled.
    a += ['mul t2,t0,t1','beq t0,t0,taken','mul s1,t0,t1','sw t0,4(s0)',
          'taken:','lw t6,4(s0)','bnez t6,fail','bnez s1,fail','li t4,5535','bne t2,t4,fail',
          'li a0,0','ebreak','fail:','li a0,1','ebreak']
    return '\n'.join(a)

def trap_program():
    return '''
      la t0,handler
      csrw mtvec,t0
      li s0,0x800f0000
      sw zero,0(s0)
      li t0,123
      li t1,45
      li s1,0
      mul s2,t0,t1
      mul s3,t0,t0
    fault:
      .word 0xffffffff
      mul s1,t0,t1
      sw t0,0(s0)
      j fail
    resume:
      bnez s1,fail
      lw t2,0(s0)
      bnez t2,fail
      li t2,5535
      bne s2,t2,fail
      li t2,15129
      bne s3,t2,fail
      li a0,0
      ebreak
    handler:
      csrr t2,mcause
      li t3,2
      bne t2,t3,fail
      csrr t2,mepc
      la t3,fault
      bne t2,t3,fail
      la t2,resume
      csrw mepc,t2
      mret
    fail:
      li a0,1
      ebreak
    '''

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--simulator',type=Path,required=True)
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    records=[]
    for name,source,diff in [('overlap',program(),True),('precise',trap_program(),False)]:
        binary=image(out,name,source)
        cmd=[str(a.simulator.resolve()),'--batch']
        if diff: cmd+=['--diff',str(NPC.parent/'nemu/build/riscv32-nemu-interpreter-so')]
        cmd+=[str(binary)];run(cmd,out/(name+'.log'))
        text=(out/(name+'.log')).read_text();assert 'HIT GOOD TRAP' in text
        cycles=int(re.search(r'CPU cycle\s*=\s*(\d+)',text)[1])
        retired=int(re.search(r'retired instructions\s*=\s*(\d+)',text)[1])
        records.append({'name':name,'cycles':cycles,'retired':retired,'difftest':diff,'command':cmd})
        print('PASS',name,cycles,retired,flush=True)
    (out/'report.json').write_text(json.dumps(records,indent=2)+'\n')
if __name__=='__main__': main()
