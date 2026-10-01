#!/usr/bin/env python3
"""Check cancellation, delayed LSU responses and identity reuse without a software timer."""
import argparse
import json
import subprocess
from pathlib import Path
from test_muldiv import NPC, run


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--lsu-entries',type=int,choices=[1,2],default=1)
    args=p.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    rtl=NPC/'vsrc/riscv32'
    flags=subprocess.check_output(['make','-s','-C',str(NPC),'NPC_CONFIG=rv32im-pipelined',
        'NPC_BACKEND_ROB_ENABLE=1','NPC_BACKEND_LOAD_OVERLAP=1',
        f'NPC_LSU_ENTRIES={args.lsu_entries}',
        '--eval=f:;@echo $(NPC_CONFIG_DEFINE)','f'],text=True).split()
    sources=[rtl/'common'/name for name in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_pkg.sv']]
    sources += [rtl/'core'/name for name in ['decode/riscv32_operand_mux.sv','decode/riscv32_scoreboard.sv',
        'writeback/riscv32_rob.sv','execute/riscv32_id_ex_reg.sv','execute/riscv32_ex_result_reg.sv',
        'execute/riscv32_exu.sv','execute/riscv32_div.sv','execute/riscv32_mul.sv',
        'frontend/riscv32_pma.sv','execute/riscv32_backend.sv']]
    sources += [NPC/'tests/backend/riscv32_backend_tb.sv']
    command=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',*flags,
        '--top-module','riscv32_backend_tb','--Mdir',str(out/'obj'),*map(str,sources)]
    run(command,out/'build.log');records=[]
    for delay in [0,1,*range(25,40),100]:
        for fault in [0,1]:
            label=f'delay{delay}-fault{fault}'
            cmd=[str(out/'obj/Vriscv32_backend_tb'),f'+delay={delay}',f'+fault={fault}']
            run(cmd,out/(label+'.log'))
            result=(out/(label+'.log')).read_text();assert 'PASS backend' in result
            records.append({'name':label,'command':cmd,'passed':True,'result':result.splitlines()[0]})
    (out/'report.json').write_text(json.dumps({'build':command,'cases':records},indent=2)+'\n')
    print(f'PASS backend recovery: {len(records)} cases')


if __name__=='__main__':main()
