#!/usr/bin/env python3
"""Build a bare-metal RV64M integration payload from independent expected values."""
import argparse, json, subprocess
from pathlib import Path
from test_execution_units import write_vectors

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
vectors, counts = write_vectors(out, 128, 20260926)
rows = [[int(v, 16) for v in line.split()] for line in vectors[1].read_text().splitlines()]
names = ['mul', 'mulh', 'mulhsu', 'mulhu', 'div', 'divu', 'rem', 'remu']
code = ['.option norvc', '.option norelax', '.section .text', '.globl _trm_init', '_trm_init:',
        '  li s0, 0', '  la s1, scratch', '  li a0, 0',
        '  li t0, 3', '  li t1, 7', '  mul t2, t0, t1', '  addi t2, t2, 1',
        '  mul t2, t2, t0', '  li t3, 66', '  bne t2, t3, fail',
        '  div t2, t2, t0', '  sd t2, 0(s1)', '  ld t3, 0(s1)',
        '  li t4, 22', '  bne t3, t4, fail', '  mul zero, t0, t1',
        '  bnez zero, fail', '  div zero, t2, t1', '  bnez zero, fail',
        '  li t4, 16', 'recovery_loop:', '  beqz zero, recovery_target',
        '  div t2, t0, zero', '  j fail', 'recovery_target:',
        '  addi t4, t4, -1', '  bnez t4, recovery_loop']
data = ['.section .data', '.balign 8', 'scratch: .quad 0']
for op, word in [(i, 0) for i in range(8)] + [(i, 1) for i in (0, 4, 5, 6, 7)]:
    selected = [r for r in rows if r[:2] == [op, word]]
    tag = names[op] + ('w' if word else '')
    code += [f'  la s2, data_{tag}', f'  li s3, {len(selected)}', f'loop_{tag}:',
             '  ld t0, 0(s2)', '  ld t1, 8(s2)', '  ld t3, 16(s2)',
             f'  {tag} t2, t0, t1', '  add t4, t2, zero',
             '  bne t4, t3, fail', '  sd t2, 0(s1)', '  ld t5, 0(s1)',
             '  bne t5, t3, fail', '  addi s0, s0, 1', '  addi s2, s2, 24',
             '  addi s3, s3, -1', f'  bnez s3, loop_{tag}']
    data += [f'data_{tag}:'] + [f'  .quad 0x{a:016x}, 0x{b:016x}, 0x{e:016x}' for _, _, a, b, e in selected]
code += ['  li a0, 0', '  ebreak', 'fail:', '  li a0, 1', '  ebreak']
source = out / 'rv64m-core.S'; source.write_text('\n'.join(code + data) + '\n')
elf, binary = out/'rv64m-core.elf', out/'rv64m-core.bin'
command = ['riscv64-linux-gnu-gcc', '-march=rv64im_zicsr_zifencei', '-mabi=lp64', '-fno-pic', '-mcmodel=medany', '-nostdlib',
           '-static', '-Wl,--no-relax,--build-id=none',
           '-T', str(Path(__file__).resolve().parents[2] / 'abstract-machine/scripts/ysyxsoc-sdram.ld'),
           '-o', str(elf), str(source),
           str(Path(__file__).resolve().parents[2] / 'abstract-machine/am/src/riscv/ysyxsoc/start-sdram.S')]
subprocess.run(command, check=True)
subprocess.run(['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
record = {'cases': len(rows), 'counts': counts, 'build_command': command, 'binary': str(binary),
          'scope': 'All RV64M operations, W upper-bit garbage, EX/result/WB forwarding, same-rd priority, load/store, rd=x0 and branch recovery'}
(out/'payload.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record))
