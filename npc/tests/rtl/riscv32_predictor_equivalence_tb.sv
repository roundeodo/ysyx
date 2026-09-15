// 拆分前后使用相同输入，每个周期核对全部外部输出；不读取DUT内部状态。
module riscv32_predictor_equivalence_case
  import riscv32_pkg::*;
#(
    parameter int unsigned CASE_INDEX = 0,
    parameter int unsigned BHT_ENTRIES = 16,
    parameter int unsigned BTB_ENTRIES = 16,
    parameter int unsigned BTB_WAYS = 2,
    parameter int unsigned RAS_ENTRIES = 4
) (
    input logic clk_i,
    output logic done_o
);
  logic rst_n;
  program_counter_t request_pc;
  fetch_epoch_t request_epoch;
  logic request_valid;
  logic response_ready;
  logic flush_lookup;
  logic invalidate;
  program_counter_t resolved_pc;
  program_counter_t resolved_target;
  xlen_data_t resolved_immediate;
  control_flow_op_e resolved_op;
  arch_reg_idx_t resolved_rs1;
  arch_reg_idx_t resolved_rd;
  logic resolved_occurred;
  logic resolved_taken;

  logic request_ready[2];
  logic response_valid[2];
  program_counter_t response_pc[2];
  fetch_epoch_t response_epoch[2];
  branch_prediction_t prediction[2];
  program_counter_t next_pc[2];

  // 唯一区别是被实例化的模块；参考源码由测试脚本从固定历史版本读取。
  riscv32_fetch_control_flow_predictor #(
      .BHT_ENTRY_COUNT(BHT_ENTRIES), .BTB_ENTRY_COUNT(BTB_ENTRIES),
      .BTB_WAY_COUNT(BTB_WAYS), .RAS_ENTRY_COUNT(RAS_ENTRIES)
  ) u_predictor (
      .clk_i(clk_i), .rst_ni(rst_n),
      .lookup_request_pc_i(request_pc), .lookup_request_epoch_i(request_epoch),
      .lookup_request_valid_i(request_valid), .lookup_request_ready_o(request_ready[0]),
      .lookup_response_pc_o(response_pc[0]), .lookup_response_epoch_o(response_epoch[0]),
      .lookup_prediction_o(prediction[0]), .lookup_next_pc_o(next_pc[0]),
      .lookup_response_valid_o(response_valid[0]), .lookup_response_ready_i(response_ready),
      .resolved_control_flow_pc_i(resolved_pc), .resolved_control_flow_target_i(resolved_target),
      .resolved_control_flow_imm_i(resolved_immediate), .resolved_control_flow_op_i(resolved_op),
      .resolved_control_flow_rs1_i(resolved_rs1), .resolved_control_flow_rd_i(resolved_rd),
      .resolved_control_flow_occurred_i(resolved_occurred),
      .resolved_control_flow_taken_i(resolved_taken),
      .flush_lookup_i(flush_lookup), .invalidate_i(invalidate)
  );

  riscv32_fetch_control_flow_predictor_reference #(
      .BHT_ENTRY_COUNT(BHT_ENTRIES), .BTB_ENTRY_COUNT(BTB_ENTRIES),
      .BTB_WAY_COUNT(BTB_WAYS), .RAS_ENTRY_COUNT(RAS_ENTRIES)
  ) u_reference (
      .clk_i(clk_i), .rst_ni(rst_n),
      .lookup_request_pc_i(request_pc), .lookup_request_epoch_i(request_epoch),
      .lookup_request_valid_i(request_valid), .lookup_request_ready_o(request_ready[1]),
      .lookup_response_pc_o(response_pc[1]), .lookup_response_epoch_o(response_epoch[1]),
      .lookup_prediction_o(prediction[1]), .lookup_next_pc_o(next_pc[1]),
      .lookup_response_valid_o(response_valid[1]), .lookup_response_ready_i(response_ready),
      .resolved_control_flow_pc_i(resolved_pc), .resolved_control_flow_target_i(resolved_target),
      .resolved_control_flow_imm_i(resolved_immediate), .resolved_control_flow_op_i(resolved_op),
      .resolved_control_flow_rs1_i(resolved_rs1), .resolved_control_flow_rd_i(resolved_rd),
      .resolved_control_flow_occurred_i(resolved_occurred),
      .resolved_control_flow_taken_i(resolved_taken),
      .flush_lookup_i(flush_lookup), .invalidate_i(invalidate)
  );

  task automatic compare_outputs(input int unsigned cycle_index);
    assert ({request_ready[0], response_valid[0], response_pc[0], response_epoch[0],
             prediction[0], next_pc[0]} ===
            {request_ready[1], response_valid[1], response_pc[1], response_epoch[1],
             prediction[1], next_pc[1]})
      else $fatal(1, "predictor mismatch: case=%0d cycle=%0d pc=%h new=%h old=%h",
                  CASE_INDEX, cycle_index, response_pc[0], prediction[0], prediction[1]);
  endtask

  function automatic arch_reg_idx_t select_register(input logic [1:0] select);
    case (select)
      2'd0: return arch_reg_idx_t'(0);
      2'd1: return arch_reg_idx_t'(1);
      2'd2: return arch_reg_idx_t'(5);
      default: return arch_reg_idx_t'(10);
    endcase
  endfunction

  logic [31:0] stimulus_state;
  int unsigned query_count;
  int unsigned response_count;
  int unsigned taken_count;
  int unsigned stall_count;
  int unsigned flush_count;
  int unsigned invalidate_count;
  int unsigned training_count;
  logic request_pending;

  initial begin
    done_o = 1'b0;
    rst_n = 1'b0;
    request_pc = '0;
    request_epoch = '0;
    request_valid = 1'b0;
    response_ready = 1'b0;
    flush_lookup = 1'b0;
    invalidate = 1'b0;
    resolved_pc = '0;
    resolved_target = '0;
    resolved_immediate = '0;
    resolved_op = CF_NONE;
    resolved_rs1 = '0;
    resolved_rd = '0;
    resolved_occurred = 1'b0;
    resolved_taken = 1'b0;
    stimulus_state = 32'h9a71_358b ^ (32'h0723_4567 * CASE_INDEX);
    query_count = 0;
    response_count = 0;
    taken_count = 0;
    stall_count = 0;
    flush_count = 0;
    invalidate_count = 0;
    training_count = 0;
    request_pending = 1'b0;
    repeat (3) @(posedge clk_i);

    for (int unsigned cycle_index = 0; cycle_index < 24000; cycle_index++) begin
      @(negedge clk_i);
      // 中途再次复位，覆盖有查询/训练在途时的状态清除。
      rst_n = !((cycle_index >= 8000 && cycle_index < 8003) ||
                (cycle_index >= 16000 && cycle_index < 16003));
      stimulus_state = {stimulus_state[30:0], stimulus_state[31] ^ stimulus_state[21] ^
                                             stimulus_state[1] ^ stimulus_state[0]};
      flush_lookup = stimulus_state[12:8] == 5'h13;
      invalidate = stimulus_state[20:15] == 6'h27;
      response_ready = stimulus_state[2] || stimulus_state[3];
      if (cycle_index % 512 < 128) begin
        flush_lookup = cycle_index % 128 == 121;
        invalidate = cycle_index % 128 == 125;
      end
      if (flush_lookup || !rst_n) begin
        request_pending = 1'b0;
        request_epoch = request_epoch + fetch_epoch_t'(1);
      end
      if (!request_pending) begin
        request_valid = stimulus_state[0] || stimulus_state[1];
        // 热点PC池既包含同set不同tag，也包含不同set。
        request_pc = program_counter_t'('h8000_0000 +
                     (int'(stimulus_state[7:4]) << 8) + (int'(stimulus_state[25:23]) << 2));
      end
      resolved_pc = program_counter_t'('h8000_0000 +
                    (int'(stimulus_state[17:14]) << 8) + (int'(stimulus_state[25:23]) << 2));
      resolved_target = program_counter_t'('h8001_0000 + (int'(stimulus_state[11:4]) << 2));
      if (stimulus_state[24:21] == 4'h9) resolved_target[1] = 1'b1;
      resolved_immediate = (stimulus_state[28:26] == 3'h7) ? xlen_data_t'(4) : '0;
      resolved_op = control_flow_op_e'(stimulus_state[31:30]);
      resolved_rs1 = select_register(stimulus_state[5:4]);
      resolved_rd = select_register(stimulus_state[7:6]);
      resolved_occurred = stimulus_state[13] && (resolved_op != CF_NONE);
      resolved_taken = stimulus_state[29] || (resolved_op != CF_BRANCH);

      // 每512拍插入连续训练：方向饱和、同set替换、栈溢出/下溢及pop+push。
      if (cycle_index % 512 < 128) begin
        resolved_occurred = 1'b1;
        resolved_immediate = '0;
        resolved_pc = program_counter_t'('h8000_0000 + ((cycle_index % 8) << 8));
        resolved_target = program_counter_t'('h8001_0000 + 4 * (cycle_index % 128));
        resolved_rs1 = '0;
        resolved_rd = '0;
        resolved_op = CF_BRANCH;
        resolved_taken = cycle_index % 64 < 32;
        case ((cycle_index % 128) / 32)
          0: begin
            resolved_pc = program_counter_t'('h8000_0000);
            resolved_taken = (cycle_index / 512) % 2 == 0;
          end
          1: begin resolved_op = CF_JAL; resolved_rd = arch_reg_idx_t'(1); end
          2: begin resolved_op = CF_JALR; resolved_rs1 = arch_reg_idx_t'(1); end
          3: begin
            resolved_op = CF_JALR;
            resolved_rs1 = arch_reg_idx_t'(1);
            resolved_rd = arch_reg_idx_t'(5);
          end
        endcase
        if (resolved_op != CF_BRANCH) resolved_taken = 1'b1;
        if (!request_pending) begin
          request_valid = 1'b1;
          request_pc = resolved_pc;
        end
      end

      #1;
      compare_outputs(cycle_index);
      if (rst_n) begin
        if (request_valid && request_ready[0]) query_count++;
        if (response_valid[0] && response_ready && !flush_lookup) begin
          response_count++;
          if (prediction[0].predicted_taken) taken_count++;
        end
        if (response_valid[0] && !response_ready) stall_count++;
        if (flush_lookup) flush_count++;
        if (invalidate) invalidate_count++;
        if (resolved_occurred) training_count++;
      end
      request_pending = rst_n && !flush_lookup && request_valid && !request_ready[0];
      @(posedge clk_i);
      #1;
      compare_outputs(cycle_index);
    end
    assert (query_count > 10000 && response_count > 10000 && taken_count > 500 &&
            stall_count > 1000 && flush_count > 100 && invalidate_count > 100 &&
            training_count > 5000)
      else $fatal(1, "insufficient predictor stimulus coverage: case=%0d", CASE_INDEX);
    $display("PASS predictor equivalence case=%0d BHT=%0d BTB=%0dx%0d RAS=%0d cycles=24000 queries=%0d responses=%0d taken=%0d stalls=%0d flush=%0d invalidate=%0d training=%0d",
             CASE_INDEX, BHT_ENTRIES, BTB_ENTRIES, BTB_WAYS, RAS_ENTRIES, query_count,
             response_count, taken_count, stall_count, flush_count, invalidate_count, training_count);
    done_o = 1'b1;
  end
endmodule

module riscv32_predictor_equivalence_tb;
  logic clk = 1'b0;
  logic [4:0] done_vector;
  always #5 clk = !clk;

  riscv32_predictor_equivalence_case #(.CASE_INDEX(0))
      u_baseline (.clk_i(clk), .done_o(done_vector[0]));
  riscv32_predictor_equivalence_case #(.CASE_INDEX(1), .BTB_WAYS(1))
      u_direct (.clk_i(clk), .done_o(done_vector[1]));
  riscv32_predictor_equivalence_case #(.CASE_INDEX(2), .BTB_WAYS(4))
      u_four_way (.clk_i(clk), .done_o(done_vector[2]));
  riscv32_predictor_equivalence_case #(.CASE_INDEX(3), .BHT_ENTRIES(2), .BTB_ENTRIES(4),
                                      .RAS_ENTRIES(2))
      u_small (.clk_i(clk), .done_o(done_vector[3]));
  riscv32_predictor_equivalence_case #(.CASE_INDEX(4), .BHT_ENTRIES(64), .BTB_ENTRIES(32),
                                      .RAS_ENTRIES(8))
      u_large (.clk_i(clk), .done_o(done_vector[4]));

  initial begin
    wait (&done_vector);
    $display("PASS predictor split: 5 configurations, 120000 compared cycles");
    $finish;
  end
  initial begin
    #300000;
    $fatal(1, "predictor equivalence test timed out");
  end
endmodule
