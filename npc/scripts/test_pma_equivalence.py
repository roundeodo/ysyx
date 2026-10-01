#!/usr/bin/env python3
"""Compare PMA attributes with a pinned pre-change RTL over boundaries and random addresses."""
import argparse
from pathlib import Path
import subprocess
import json
import hashlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reference-revision', default='5493a6aec976f4f9bdc075834d3f1202b0ae16ef')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    rtl = root / 'npc/vsrc/riscv32'
    candidate = rtl / 'core/frontend/riscv32_pma.sv'
    reference_text = subprocess.check_output([
        'git', '-C', str(root), 'show', args.reference_revision + ':' + str(candidate.relative_to(root))], text=True)
    reference = out / 'reference.sv'
    reference.write_text(reference_text.replace('module riscv32_pma', 'module riscv32_pma_reference'))
    regions=['CLINT','SRAM','UART','SPI_REG','GPIO','PS2','MROM','VGA','FLASH','CHIPLINK_MMIO','PSRAM','SDRAM','CHIPLINK_MEMORY']
    checks='\n'.join(f'    for (int delta=-2; delta<=2; delta++) begin check({r}_BASE_ADDR+32\'(delta)); check({r}_LAST_ADDR+32\'(delta)); end' for r in regions)
    (out/'pma_tb.sv').write_text('''module pma_tb;
     import riscv32_pkg::*;
     import riscv32_addr_map_pkg::*;
     logic [31:0] addr;
     pma_attr_t actual[2], expected[2];
     for (genvar i=0;i<2;i++) begin : gen_mode
       riscv32_pma #(.CHIPLINK_PRESENT(i!=0)) dut(.lookup_addr_i(addr),.memory_attr_o(actual[i]));
       riscv32_pma_reference #(.CHIPLINK_PRESENT(i!=0)) ref_dut(.lookup_addr_i(addr),.memory_attr_o(expected[i]));
     end
     task automatic check(input logic [31:0] address);
       addr=address; #1;
       for (int i=0;i<2;i++) assert(actual[i]===expected[i])
         else $fatal(1,"PMA addr=%h chiplink=%0d actual=%h reference=%h",address,i,actual[i],expected[i]);
     endtask
     int seed=20260929;
     initial begin
       void'($urandom(seed));
    ''' + checks + '''
       repeat(200000) check($urandom);
       $display("PASS PMA: 200000 random addresses and 130 boundary addresses, CHIPLINK 0/1");
       $finish;
     end
    endmodule
    ''')
    sources = [rtl / 'common' / name for name in
               ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_pkg.sv']]
    sources += [candidate, reference, out / 'pma_tb.sv']
    flags = subprocess.check_output([
        'make', '-s', '-C', str(root / 'npc'), 'NPC_CONFIG=rv32im-pipelined',
        '--eval=pma-flags:;@echo $(NPC_CONFIG_DEFINE)', 'pma-flags'], text=True).split()
    command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
               *flags, '--top-module', 'pma_tb', '--Mdir', str(out / 'obj'), *map(str, sources)]
    with (out / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    with (out / 'run.log').open('w') as log:
        subprocess.run([str(out / 'obj/Vpma_tb')], stdout=log, stderr=subprocess.STDOUT, check=True)
    print((out / 'run.log').read_text().splitlines()[0])
    report = {
        'passed': True,
        'reference_revision': args.reference_revision,
        'random_addresses': 200000,
        'boundary_addresses': 130,
        'chiplink': [0, 1],
        'command': command,
        'sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    }
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == "__main__":
    main()
