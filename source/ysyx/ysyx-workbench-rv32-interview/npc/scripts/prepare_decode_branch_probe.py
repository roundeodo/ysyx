#!/usr/bin/env python3
"""Build an isolated necessary-path experiment: forwarded branch comparison in ID.

This is not an enabled early-redirect implementation. It moves the real condition
comparison to the existing ID/EX boundary so STA can test a prerequisite before
adding decode recovery arbitration. The current core and interfaces stay intact.
"""
import hashlib
import json
from pathlib import Path
import shutil

NPC = Path(__file__).resolve().parents[1]
OUTPUT = NPC / 'result/decode-branch-probe'


def main():
    # This source-only directory is ours; never remove unrelated result trees.
    OUTPUT.mkdir(parents=True, exist_ok=True)
    destination = OUTPUT / 'source'
    if destination.exists():
        if not (OUTPUT / '.decode-branch-probe').is_file():
            raise RuntimeError('Refusing to overwrite an unowned experiment')
        shutil.rmtree(destination)
    (OUTPUT / '.decode-branch-probe').write_text('source-only decode comparison experiment\n')
    shutil.copytree(NPC / 'vsrc/riscv32', destination)
    package = destination / 'common/riscv32_pkg.sv'
    text = package.read_text()
    marker = '    xlen_data_t source_a_value;'
    assert text.count(marker) == 1
    package.write_text(text.replace(marker, '    logic branch_condition;\n' + marker))

    execute = destination / 'core/execute/riscv32_exu.sv'
    text = execute.read_text()
    first = text.index('  localparam int unsigned COMPARE_GROUP_BITS')
    last = text.index('`endif', first)
    comparator = text[first:last].replace('execute_rs1_value', 'decoded_execute_packet.source_a_value')
    comparator = comparator.replace('execute_rs2_value', 'decoded_execute_packet.source_b_value')
    first = text.index('  always_comb begin\n    unique case (execute_packet_i.uop.branch_ctrl.condition)')
    last = text.index('\n  always_comb begin', first + 10)
    text = text[:first] + '  assign branch_condition_met = execute_packet_i.branch_condition;\n' + text[last:]
    execute.write_text(text)

    core = destination / 'core/riscv32_core.sv'
    text = core.read_text()
    marker = '  riscv32_id_ex_reg u_id_ex_reg ('
    assert text.count(marker) == 1
    decision = '''  // Experimental necessary path: retain the exact forwarded operands and
  // compare before the existing ID/EX edge. No frontend redirect is added yet.
'''+comparator+'''
  execute_packet_t branch_decoded_packet;
  always_comb begin
    branch_decoded_packet = decoded_execute_packet;
    branch_decoded_packet.branch_condition = 1'b0;
    unique case (decoded_execute_packet.uop.branch_ctrl.condition)
      BR_BEQ:  branch_decoded_packet.branch_condition = operands_equal;
      BR_BNE:  branch_decoded_packet.branch_condition = !operands_equal;
      BR_BLT:  branch_decoded_packet.branch_condition = operands_signed_less;
      BR_BGE:  branch_decoded_packet.branch_condition = !operands_signed_less;
      BR_BLTU: branch_decoded_packet.branch_condition = operands_unsigned_less;
      BR_BGEU: branch_decoded_packet.branch_condition = !operands_unsigned_less;
      default: ;
    endcase
  end

'''
    text = text.replace(marker, decision + marker)
    text = text.replace('(decoded_execute_packet),\n      .decoded_execute_packet_valid_i',
                        '(branch_decoded_packet),\n      .decoded_execute_packet_valid_i')
    assert '(branch_decoded_packet)' in text
    core.write_text(text)
    for filelist in (destination / 'filelist').glob('*.f'):
        filelist.write_text(filelist.read_text().replace('${NPC_HOME}/vsrc/riscv32', str(destination)))
    manifest = {'scope': 'necessary comparison path only; no early redirect; not a default configuration',
                'sources': {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in destination.rglob('*.sv')},
                'sta_filelist': str(destination / 'filelist/filelist_sta.f')}
    (OUTPUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(manifest['sta_filelist'])


if __name__ == '__main__':
    main()
