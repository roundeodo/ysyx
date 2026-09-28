#!/usr/bin/env python3
"""Exercise true multiply overlap, Python arithmetic oracle, stalls and cancellation."""
import argparse
import hashlib
import json
import random
import resource
import subprocess
from pathlib import Path
from test_muldiv import NPC, vectors, run

def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args(); out = a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(0x32_09_28)
    rows = [(0, i+3, i+17, ((i+3)*(i+17)) & 0xffffffff, 0) for i in range(160)]
    for index, (op, x, y, expected, _, abort) in enumerate(vectors()):
        if abort >= 0:
            continue
        rows.append((op, x, y, expected, 2 if index % 19 == 0 else 1))
        if index % 3 == 0:
            x, y = rng.getrandbits(32), rng.getrandbits(32)
            rows.append((8, x, y, (x+y)&0xffffffff, 1))
    vector_file = out/'vectors.txt'
    vector_file.write_text(''.join(f'{op} {x:08x} {y:08x} {expected:08x} {mode}\n'
                                  for op,x,y,expected,mode in rows))
    rtl = NPC/'vsrc/riscv32'
    sources = [rtl/'common'/name for name in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_pkg.sv']]
    sources += [rtl/'core/decode/riscv32_idu.sv', *sorted((rtl/'core/execute').glob('*.sv')),
                NPC/'tests/muldiv/riscv32_mul_pipeline_tb.sv']
    flags = subprocess.check_output(['make','-s','-C',str(NPC),'NPC_CONFIG=rv32im-pipelined',
        '--eval=flags:;@echo $(NPC_CONFIG_DEFINE)','flags'],text=True).split()
    command = ['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',*flags,
               '--top-module','riscv32_mul_pipeline_tb','--Mdir',str(out/'obj'),*map(str,sources)]
    run(command,out/'build.log')
    run([str(out/'obj/Vriscv32_mul_pipeline_tb'),f'+vectors={vector_file}'],out/'run.log')
    print((out/'run.log').read_text())
    (out/'report.json').write_text(json.dumps({'passed':True,'vectors':len(rows),
        'build_command':command,'result':(out/'run.log').read_text(),
        'sources':{str(x.relative_to(NPC)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sources}},indent=2)+'\n')
if __name__ == '__main__': main()
