#!/usr/bin/env python3
"""Simulation-only no-prediction/oracle controls, isolated from production RTL and PPA."""
import argparse
import json
from pathlib import Path
import shutil
import explore_frontend as experiment
from followup_branch import defines


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();source=root/'diagnostic-source'
    shutil.copytree(root/'baseline/npc/vsrc',source/'npc/vsrc')
    shutil.copytree(root/'baseline/npc/tests/frontend_exploration',source/'npc/tests/frontend_exploration')
    path=source/'npc/vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv';s=path.read_text()
    anchor='  // 3. 预测选择：BTB 决定指令种类，BHT 决定条件分支方向，RAS 提供返回目标。'
    extra='''  // Simulation diagnostic only: mode 0 original; 1 no prediction; 2 future-path oracle.
  // No retirement result, memory data or architectural control is overridden.
  int diagnostic_mode = 0, oracle_count = 0, oracle_index = 0;
  logic [31:0] oracle_pc_array[2097152];
  string oracle_file;
  initial begin
    void'($value$plusargs("prediction_mode=%d", diagnostic_mode));
    if (diagnostic_mode == 2) begin
      if (!$value$plusargs("oracle=%s", oracle_file) ||
          !$value$plusargs("oracle_count=%d", oracle_count) ||
          oracle_count < 2 || oracle_count > 2097152)
        $fatal(1, "missing or invalid oracle trace");
      $readmemh(oracle_file, oracle_pc_array, 0, oracle_count - 1);
    end
  end
  always @(posedge clk_i) begin
    if (!rst_ni) oracle_index = 0;
    else if (diagnostic_mode == 2 && lookup_request_valid_i && lookup_request_ready_o &&
             oracle_index < oracle_count - 1) begin
      if (lookup_request_pc_i != oracle_pc_array[oracle_index])
        $fatal(1, "oracle query identity mismatch index=%0d pc=%h expected=%h", oracle_index,
               lookup_request_pc_i, oracle_pc_array[oracle_index]);
      oracle_index <= oracle_index + 1;
    end
  end

'''
    assert anchor in s;s=s.replace(anchor,extra+anchor)
    anchor="    selected_prediction                  = '0;"
    override='''    if (diagnostic_mode == 1) selected_taken = 1'b0;
    if (diagnostic_mode == 2 && oracle_index < oracle_count - 1) begin
      selected_target_pc = oracle_pc_array[oracle_index + 1];
      selected_taken = selected_target_pc != lookup_request_pc_i + program_counter_t'(4);
    end
'''
    assert anchor in s;s=s.replace(anchor,override+anchor);path.write_text(s)
    (source/'diagnostic-manifest.json').write_text(json.dumps({'mode0':'original prediction',
       'mode1':'all predictions not taken','mode2':'future correct-path PC sequence, zero added oracle access latency',
       'limits':'development diagnostics only, not synthesizable candidate; memory model and retirement checks unchanged',
       'modified_file':str(path),'sha256':experiment.sha(path)},indent=2)+'\n')
    experiment.TEST=source/'npc/tests/frontend_exploration'
    experiment.build_rtl(root/'builds/diagnostic',source/'npc/vsrc/riscv32',defines({'bht':16}),host_opt=2)


if __name__=='__main__':main()
