#!/usr/bin/env python3
"""Post-selection limitation probe: repeated calls across a 64 KiB boundary."""
import argparse
import json
from pathlib import Path
import subprocess
from evaluate_target_storage import measure, compare
from explore_frontend import sha


def apply_boundary_guard(root):
    decision = json.loads((root/'decision.json').read_text())
    (root/'aggregate-decision.json').write_text(json.dumps(decision,indent=2)+'\n')
    probe = json.loads((root/'far-calls.json').read_text())
    chosen = decision['development_choice']
    decision['profile_recommendation'] = decision['recommendation']
    decision['boundary_probe'] = {'time_ratio':probe['results'][chosen]['time_ratio_gm'],
                                  'excluded_from_profile_weighting':True}
    if probe['results'][chosen]['max_input_time_ratio'] > 1.03:
        decision['recommendation'] = 'B0'
        decision['reason'] = 'Selected prototype passes held/layout profiles, but repeated cross-64KiB calls exceed the regression guard; retain as an opt-in area experiment'
    decision['note'] = 'No retuning or selection of another winner after held evaluation; general-default fallback only'
    (root/'decision.json').write_text(json.dumps(decision,indent=2)+'\n')


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();assert (root/'selection-freeze.json').exists()
    images=root/'boundary-probe';folder=images/'far_calls-dev';folder.mkdir(parents=True,exist_ok=False)
    source=folder/'program.S';source.write_text(''' .section .text.start
 .globl _start, workload_begin, workload_end
_start:
 li sp, 0x80020000
workload_begin:
 li a0, 0
 li a1, 64
loop:
 jal ra, remote
 addi a1, a1, -1
 bnez a1, loop
workload_end:
 li t0, 0x10002000
 sw a0, 0(t0)
1: j 1b
 .section .text.remote
remote:
 addi a0, a0, 1
 ret
''')
    linker=folder/'link.ld';linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; .text : { *(.text.start) } . = 0x80010000; .remote : { *(.text.remote) } }\n')
    elf=folder/'image.elf';binary=folder/'image.bin'
    cmd=['riscv64-linux-gnu-gcc','-march=rv32i_zicsr_zifencei','-mabi=ilp32','-nostdlib','-static',
         '-Wl,--build-id=none','-T',str(linker),str(source),'-o',str(elf)]
    subprocess.run(cmd,check=True)
    subprocess.run(['riscv64-linux-gnu-objcopy','-O','binary',str(elf),str(binary)],check=True)
    data=binary.read_bytes();data+=b'\0'*(-len(data)%4)
    (folder/'image.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4)))
    symbols=subprocess.check_output(['riscv64-linux-gnu-nm',str(elf)],text=True)
    addresses={r.split()[2]:int(r.split()[0],16) for r in symbols.splitlines() if len(r.split())==3}
    case={'name':folder.name,'kind':'far_calls','held':False,'seed':None,'expected':64,
          'begin_pc':addresses['workload_begin'],'end_pc':addresses['workload_end'],'command':cmd,
          'hashes':{p.name:sha(p) for p in [source,linker,elf,binary,folder/'image.hex']}}
    (images/'manifest.json').write_text(json.dumps({'scope':'post-selection boundary stress; excluded from tuning, held weighting and winner selection','cases':[case]},indent=2)+'\n')
    common=json.loads((root/'development-summary.json').read_text())['common_mhz']
    results={n:measure(root,n,'far-calls',common,images=images) for n in ['B0','U16','H32']}
    report={n:compare(results['B0'],results[n],1) for n in results}
    (root/'far-calls.json').write_text(json.dumps({'common_mhz':common,'scope':'performance limitation only, not workload aggregate; area excluded', 'results':report},indent=2)+'\n')
    apply_boundary_guard(root)
    print('PASS far-call correctness and measured regression',json.dumps(report),flush=True)


if __name__=='__main__':main()
