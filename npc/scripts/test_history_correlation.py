#!/usr/bin/env python3
"""Positive/control diagnostic for correlated branches; never included in workload score."""
import argparse
import json
from pathlib import Path
import subprocess
from explore_frontend import NPC,run,sha
from audit_branch_penalty import parse


def expected(iterations):
    state=0x15263748;count=0
    def step(x):
        x=(x^(x<<13))&0xffffffff;x^=x>>17
        return (x^(x<<5))&0xffffffff
    for _ in range(iterations):
        state=step(state);a=state&1
        state=step(state);b=state&1
        count+=a^b
    return count


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();out=root/'correlation-diagnostic';out.mkdir(exist_ok=False)
    rows=[];iterations=1024
    shift='''  slli t2, t0, 13
  xor t0, t0, t2
  srli t2, t0, 17
  xor t0, t0, t2
  slli t2, t0, 5
  xor t0, t0, t2
'''
    for gap in [0,8]:
        folder=out/f'gap{gap}';folder.mkdir()
        text='''.section .text.start
.globl _start
.option norvc
.option norelax
_start:
  li t0, 0x15263748
  li a0, 0
  li t4, 0
  li t5, 0
  li a1, 1024
begin:
  nop
loop:
'''+shift+'''  andi t1, t0, 1
branch_a:
  beq t1, zero, after_a
  addi t4, t4, 1
after_a:
'''+shift+'''  andi t3, t0, 1
branch_b:
  beq t3, zero, after_b
  addi t5, t5, 1
after_b:
'''+('  nop\n'*gap)+'''  xor t6, t1, t3
branch_xor:
  beq t6, zero, after_xor
  addi a0, a0, 1
after_xor:
  addi a1, a1, -1
loop_branch:
  bne a1, zero, loop
end:
  nop
  li t2, 0x10002000
  sw a0, 0(t2)
1: j 1b
'''
        (folder/'program.S').write_text(text)
        cmd=['riscv64-linux-gnu-gcc','-march=rv32i_zicsr_zifencei','-mabi=ilp32','-fno-pic',
             '-nostdlib','-static','-Wl,--build-id=none','-T',NPC/'tests/frontend_exploration/link.ld',
             folder/'program.S','-o',folder/'image.elf']
        run(cmd,folder/'build.log');run(['riscv64-linux-gnu-objcopy','-O','binary',folder/'image.elf',folder/'image.bin'],folder/'objcopy.log')
        data=(folder/'image.bin').read_bytes();(folder/'image.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4)))
        symbols=subprocess.check_output(['riscv64-linux-gnu-nm',str(folder/'image.elf')],text=True)
        symbols={x.split()[2]:int(x.split()[0],16) for x in symbols.splitlines() if len(x.split())==3}
        reference=None
        for name in ['B0','B0I','B512','G256','G512','T16','T32']:
            mapping=json.loads((root/'build-map.json').read_text()) if (root/'build-map.json').exists() else {}
            build=mapping.get(name,name)
            binary=root/'builds'/build/'obj/Vexploration_core_tb'
            command=[binary,f'+image={folder/"image.hex"}',f'+begin_pc={symbols["begin"]:x}',
                     f'+end_pc={symbols["end"]:x}',f'+expected={expected(iterations):x}',
                     '+cpu_mhz=700','+latency_ns=100','+beat_ns=10','+memory_mode=physical',
                     '+random_stalls=0','+seed=97531']
            log=folder/(name+'.log');run(command,log);result=parse(log.read_text(),'RESULT')
            counters=parse(log.read_text(),'COUNTERS');detail=parse(log.read_text(),'DETAIL')
            if reference is None:reference=result
            for key in ['retired','all_retired','digest','checksum']:assert result[key]==reference[key]
            rows.append({'gap_nops':gap,'config':name,'result':result,'counters':counters,'detail':detail,
                         'cycle_ratio':result['cycles']/reference['cycles'],'command':list(map(str,command)),
                         'image_sha256':sha(folder/'image.bin'),'binary_sha256':sha(binary),
                         'branch_pc':{k:symbols[k] for k in ['branch_a','branch_b','branch_xor','loop_branch']}})
            print('PASS correlation',gap,name,result['cycles'],detail['direction'],flush=True)
    (out/'results.json').write_text(json.dumps({'scope':'synthetic XOR correlation control; two spacing variants; not weighted application evidence or a tuning input','results':rows},indent=2)+'\n')

if __name__=='__main__':main()
