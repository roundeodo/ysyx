#!/usr/bin/env python3
"""Prove the actual RV32 EXU address circuit for every base and signed 12-bit offset."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = NPC / 'vsrc/riscv32/core/execute/riscv32_exu.sv'
    rtl = source.read_text()
    # Extract the implementation being synthesized, rather than mirror it in the test.
    circuit = rtl.split('begin : gen_rv32_address\n', 1)[1].split('  end else begin : gen_wide_address', 1)[0]
    circuit = circuit.replace('execute_rs1_value', 'base_i').replace('execute_packet_i.uop.imm', 'offset_i')
    proof = output / 'address_miter.sv'
    proof.write_text('module address_miter(input [31:0] base_i, input [11:0] offset_i, output correct);\n'
                     'wire [31:0] base_offset_addr;\n' + circuit +
                     '\nassign correct = base_offset_addr == (base_i + {{20{offset_i[11]}},offset_i});\nendmodule\n')
    command = ['yosys', '-p', f'read_verilog -sv {proof}; prep -top address_miter; flatten; '
               'sat -verify -prove correct 1 -show-inputs -show-outputs']
    with (output / 'proof.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    assert 'SUCCESS' in (output / 'proof.log').read_text()
    result = {'passed': True, 'input_bits_exhaustively_proved': 44,
              'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'command': command}
    (output / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS: EXU address matches 32-bit modular addition for every base and signed 12-bit offset')


if __name__ == '__main__':
    main()
