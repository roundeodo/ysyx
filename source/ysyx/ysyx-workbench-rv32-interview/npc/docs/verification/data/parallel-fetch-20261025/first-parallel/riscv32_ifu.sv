// IFU：同一PC并行查询预测器/I-cache → 响应配对 → 早期纠错与交付。
module riscv32_ifu
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
#(
    parameter program_counter_t PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t redirect_req_i,
    input logic          redirect_req_valid_i,
    // 维护期间只停止新预测；已展示的 I-cache 请求仍按原握手排空。
    input logic          prediction_enable_i,

    input logic early_return_present_i,
    input program_counter_t early_return_pc_i,

    // 查询与I-cache同拍发出。预测响应保持到对应指令交付，不再串在cache请求之前。
    output program_counter_t   next_pc_predictor_lookup_request_pc_o,
    output fetch_epoch_t       next_pc_predictor_lookup_request_epoch_o,
    output logic               next_pc_predictor_lookup_request_valid_o,
    input  logic               next_pc_predictor_lookup_request_ready_i,
    input  program_counter_t   next_pc_predictor_lookup_response_pc_i,
    input  fetch_epoch_t       next_pc_predictor_lookup_response_epoch_i,
    input  branch_prediction_t next_pc_predictor_prediction_i,
    input  logic               next_pc_predictor_lookup_response_valid_i,
    output logic               next_pc_predictor_lookup_response_ready_o,
    output logic               next_pc_predictor_flush_o,

    // IFU只传递取指语义；cache组织、refill和AXI4均位于I-cache边界之后。
    output icache_lookup_req_t  icache_lookup_req_o,
    output logic                icache_lookup_req_valid_o,
    input  logic                icache_lookup_req_ready_i,
    input  icache_lookup_resp_t icache_lookup_resp_i,
    // 仅用于并行预译码；错误返回仍禁止预测覆盖和局部恢复。
    input  icache_fetch_data_t icache_lookup_word_i,
    input  logic                icache_lookup_resp_valid_i,
    output logic                icache_lookup_resp_ready_o,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_entry_valid_o,
    input  logic         fetch_entry_ready_i
);

  // 内部早期恢复只丢年轻取指；当前fetch_entry与已进入fetch buffer的老指令继续交付。
  logic early_redirect_event;
  logic frontend_restart_event;
  program_counter_t early_next_pc;
  assign frontend_restart_event = redirect_req_valid_i || early_redirect_event;

  // 1. 返回配对：阻塞cache只有一个未响应请求，预测响应寄存器直接保存其元数据。
  // 命中时两路在同一拍返回；miss或下游反压时保持预测，直到对应指令被接收。
  fetch_epoch_t current_fetch_epoch_q;
  logic predictor_lookup_response_is_current;
  logic icache_lookup_response_is_current;
  logic predictor_lookup_response_handshake;
  logic icache_lookup_response_handshake;
  branch_prediction_t response_prediction;
  program_counter_t predicted_next_pc;

  assign predictor_lookup_response_is_current =
      next_pc_predictor_lookup_response_epoch_i == current_fetch_epoch_q;
  assign icache_lookup_response_is_current =
      icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q;
  assign response_prediction = next_pc_predictor_prediction_i;
  assign predicted_next_pc = response_prediction.predicted_taken ?
      response_prediction.predicted_target :
      next_pc_predictor_lookup_response_pc_i + program_counter_t'(INSTRUCTION_BYTES);
  assign icache_lookup_response_handshake =
      icache_lookup_resp_valid_i && icache_lookup_resp_ready_o;
  assign next_pc_predictor_lookup_response_ready_o = !frontend_restart_event &&
      (!predictor_lookup_response_is_current ||
       (icache_lookup_response_handshake && icache_lookup_response_is_current));
  assign predictor_lookup_response_handshake =
      next_pc_predictor_lookup_response_valid_i && next_pc_predictor_lookup_response_ready_o;
  assign next_pc_predictor_flush_o = frontend_restart_event;

  // 2. 请求分发：预测表与cache读取同一个PC，互相不等待查询结果。
  // 预测器ready允许替换已消费的响应；cache暂不ready时，只保存已展示请求。
  // 该请求的预测已经被接收，不能再次查询或因redirect而撤销cache端的valid。
  program_counter_t fetch_pc_q, fetch_pc_d;
  frontend_tag_t next_frontend_tag_q;
  icache_lookup_req_t held_request_q;
  logic held_request_present_q;
  logic new_request_valid;
  logic predictor_lookup_request_handshake;
  logic icache_lookup_request_handshake;

  assign new_request_valid = !held_request_present_q && prediction_enable_i &&
      !frontend_restart_event && next_pc_predictor_lookup_request_ready_i;
  assign next_pc_predictor_lookup_request_pc_o =
      (next_pc_predictor_lookup_response_valid_i && predictor_lookup_response_is_current) ?
      predicted_next_pc : fetch_pc_q;
  assign next_pc_predictor_lookup_request_epoch_o = current_fetch_epoch_q;
  assign next_pc_predictor_lookup_request_valid_o = new_request_valid;
  assign predictor_lookup_request_handshake = new_request_valid &&
      next_pc_predictor_lookup_request_ready_i;

  always_comb begin
    icache_lookup_req_o = '0;
    icache_lookup_req_o.fetch_addr = phys_addr_t'(next_pc_predictor_lookup_request_pc_o);
    icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
    icache_lookup_req_o.fetch_epoch = current_fetch_epoch_q;
    if (held_request_present_q)
      icache_lookup_req_o = held_request_q;
  end
  assign icache_lookup_req_valid_o = held_request_present_q || new_request_valid;
  assign icache_lookup_request_handshake = icache_lookup_req_valid_o && icache_lookup_req_ready_i;

  always_comb begin
    fetch_pc_d = fetch_pc_q;
    if (predictor_lookup_response_handshake && predictor_lookup_response_is_current)
      fetch_pc_d = predicted_next_pc;
    if (predictor_lookup_request_handshake)
      fetch_pc_d = next_pc_predictor_lookup_request_pc_o + program_counter_t'(INSTRUCTION_BYTES);
    if (frontend_restart_event)
      fetch_pc_d = redirect_req_valid_i ? redirect_req_i.target_pc : early_next_pc;
  end

  // PC仅随新预测推进；旧epoch的cache请求迟到握手不能覆盖恢复PC。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pc_q <= PC_START;
      current_fetch_epoch_q <= '0;
      next_frontend_tag_q <= '0;
    end else begin
      fetch_pc_q <= fetch_pc_d;
      if (frontend_restart_event)
        current_fetch_epoch_q <= current_fetch_epoch_q + fetch_epoch_t'(1);
      if (predictor_lookup_request_handshake)
        next_frontend_tag_q <= next_frontend_tag_q + frontend_tag_t'(1);
    end
  end

  // 空时直通，首次受阻才保存；包括维护/恢复在内，只有cache握手能释放已展示请求。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      held_request_present_q <= 1'b0;
    else if (icache_lookup_request_handshake)
      held_request_present_q <= 1'b0;
    else if (new_request_valid)
      held_request_present_q <= 1'b1;
  end
  always_ff @(posedge clk_i) begin
    if (new_request_valid && !icache_lookup_req_ready_i)
      held_request_q <= icache_lookup_req_o;
  end

  // 3a. 返回指令译码：B/J直接目标与可选返回地址预测并行。
  logic early_control_flow_present, early_taken;
  logic direct_control_flow_present, direct_taken;
  program_counter_t direct_target;
  logic instruction_is_return, return_rs1_link, return_rd_link;
  instruction_t returned_instruction;
  assign returned_instruction = icache_lookup_word_i;
  assign return_rs1_link = returned_instruction[19:15] inside {5'd1, 5'd5};
  assign return_rd_link = returned_instruction[11:7] inside {5'd1, 5'd5};
  assign instruction_is_return = returned_instruction[6:0] == 7'b1100111 &&
      returned_instruction[14:12] == 3'b000 && returned_instruction[31:20] == 12'b0 &&
      return_rs1_link && (!return_rd_link || returned_instruction[11:7] != returned_instruction[19:15]);
  // 解析RAS可在返回响应被反压时变化；首次受阻才保留其当时值。
  logic return_hold_present_q, return_hold_target_present_q;
  program_counter_t return_hold_pc_q;
  logic selected_return_target_present;
  program_counter_t selected_return_pc;
  // 3b. 返回栈快照：首次受阻才保存；同一响应交付或外部恢复时释放。
  if (riscv_config_pkg::BRANCH_EARLY_RAS) begin : g_return_hold
    assign selected_return_target_present = return_hold_present_q ?
        return_hold_target_present_q : early_return_present_i;
    assign selected_return_pc = return_hold_present_q ? return_hold_pc_q : early_return_pc_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)
        return_hold_present_q <= 1'b0;
      else if (redirect_req_valid_i || (fetch_entry_valid_o && fetch_entry_ready_i))
        return_hold_present_q <= 1'b0;
      else if (fetch_entry_valid_o && !fetch_entry_ready_i && instruction_is_return)
        return_hold_present_q <= 1'b1;
    end
    always_ff @(posedge clk_i) begin
      if (fetch_entry_valid_o && !fetch_entry_ready_i && instruction_is_return &&
          !return_hold_present_q) begin
        return_hold_target_present_q <= early_return_present_i;
        return_hold_pc_q <= early_return_pc_i;
      end
    end
  end else begin : g_no_return_hold
    assign return_hold_present_q = 1'b0;
    assign return_hold_target_present_q = 1'b0;
    assign return_hold_pc_q = '0;
    assign selected_return_target_present = 1'b0;
    assign selected_return_pc = '0;
  end
  // 3c. 直接目标：指令立即数加PC，沿用请求时的方向计数器快照。
  program_counter_t early_target, fetch_sequential_pc;
  logic early_next_pc_mismatch;
  if (riscv_config_pkg::BRANCH_EARLY_TARGET) begin : g_early_target
    riscv32_direct_target u_direct_target (
        .pc_i(program_counter_t'(icache_lookup_resp_i.fetch_addr)),
        .instruction_i(icache_lookup_word_i),
        .direction_counter_i(response_prediction.raw_direction_counter),
        .known_o(direct_control_flow_present), .taken_o(direct_taken), .target_o(direct_target));
  end else begin : g_no_early_target
    assign direct_control_flow_present = 1'b0;
    assign direct_taken = 1'b0;
    assign direct_target = '0;
  end
  always_comb begin
    early_control_flow_present = direct_control_flow_present;
    early_taken = direct_taken;
    early_target = direct_target;
    if (riscv_config_pkg::BRANCH_EARLY_RAS && instruction_is_return && selected_return_target_present) begin
      early_control_flow_present = 1'b1;
      early_taken = 1'b1;
      early_target = selected_return_pc;
    end
  end
  // 3d. 下一PC比较：交付当前指令时只取消年轻请求，外部恢复优先。
  assign fetch_sequential_pc = program_counter_t'(icache_lookup_resp_i.fetch_addr) +
      program_counter_t'(INSTRUCTION_BYTES);
  assign early_next_pc = early_taken ? early_target : fetch_sequential_pc;
  // 各后继地址先并行比较，再用方向选择一位结果；不串联两个宽地址 mux 与比较器。
  assign early_next_pc_mismatch = response_prediction.predicted_taken ?
      (early_taken ? early_target != response_prediction.predicted_target :
                     fetch_sequential_pc != response_prediction.predicted_target) :
      (early_taken && early_target != fetch_sequential_pc);
  assign early_redirect_event = early_control_flow_present && !icache_lookup_resp_i.access_fault &&
      (!early_taken || early_target[1:0] == 2'b00) && early_next_pc_mismatch &&
      fetch_entry_valid_o && fetch_entry_ready_i;

  // 3e. 响应交付：指令、异常与更新后的预测信息由此处统一打包。
  always_comb begin
    fetch_entry_o                 = '0;
    fetch_entry_o.pc              = program_counter_t'(icache_lookup_resp_i.fetch_addr);
    fetch_entry_o.instruction     = icache_lookup_resp_i.fetch_data;
    fetch_entry_o.frontend_tag    = icache_lookup_resp_i.frontend_tag;
    fetch_entry_o.prediction      = response_prediction;
    if (early_control_flow_present && !icache_lookup_resp_i.access_fault &&
        (!early_taken || early_target[1:0] == 2'b00)) begin
      fetch_entry_o.prediction.predicted_taken = early_taken;
      fetch_entry_o.prediction.predicted_target = early_taken ? early_target : '0;
    end
    fetch_entry_o.exception_valid = icache_lookup_resp_i.access_fault;
    fetch_entry_o.exception_cause = EXC_INSTR_ACCESS_FAULT;
    fetch_entry_o.exception_tval  = xlen_data_t'(icache_lookup_resp_i.fetch_addr);

    fetch_entry_valid_o = icache_lookup_resp_valid_i &&
                          icache_lookup_response_is_current &&
                          next_pc_predictor_lookup_response_valid_i &&
                          !redirect_req_valid_i;
    icache_lookup_resp_ready_o =
        (!icache_lookup_response_is_current || redirect_req_valid_i) ?
        1'b1 : (fetch_entry_ready_i && next_pc_predictor_lookup_response_valid_i);
  end

`ifndef SYNTHESIS
  // 仅验证请求身份与在途数；不为芯片添加tag表或重复预测状态。
  icache_lookup_req_t accepted_request_q;
  logic accepted_request_present_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      accepted_request_present_q <= 1'b0;
    else begin
      if (icache_lookup_response_handshake)
        accepted_request_present_q <= 1'b0;
      if (icache_lookup_request_handshake) begin
        accepted_request_q <= icache_lookup_req_o;
        accepted_request_present_q <= 1'b1;
      end
    end
  end

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_lookup_request_handshake |->
      (!accepted_request_present_q || icache_lookup_response_handshake))
  else $error("Blocking I-cache accepted a second outstanding lookup");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_lookup_resp_valid_i |->
      (accepted_request_present_q && icache_lookup_resp_i.fetch_addr == accepted_request_q.fetch_addr &&
       icache_lookup_resp_i.fetch_epoch == accepted_request_q.fetch_epoch &&
       icache_lookup_resp_i.frontend_tag == accepted_request_q.frontend_tag))
  else $error("I-cache response changed request identity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_lookup_resp_valid_i && icache_lookup_response_is_current && !redirect_req_valid_i) |->
      (next_pc_predictor_lookup_response_valid_i && predictor_lookup_response_is_current &&
       next_pc_predictor_lookup_response_pc_i == program_counter_t'(icache_lookup_resp_i.fetch_addr)))
  else $error("Parallel cache and predictor responses lost pairing");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    predictor_lookup_request_handshake |->
      (icache_lookup_req_valid_o && !held_request_present_q &&
       icache_lookup_req_o.fetch_addr == phys_addr_t'(next_pc_predictor_lookup_request_pc_o) &&
       icache_lookup_req_o.fetch_epoch == next_pc_predictor_lookup_request_epoch_o))
  else $error("Prediction query did not launch with the same cache request");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    !prediction_enable_i |-> !next_pc_predictor_lookup_request_valid_o)
  else $error("IFU queried while prediction was disabled");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (fetch_entry_valid_o && !fetch_entry_ready_i && !redirect_req_valid_i)
    |=> (redirect_req_valid_i || (fetch_entry_valid_o && $stable(fetch_entry_o))))
  else $error("IFU changed a presented fetch entry while stalled");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_lookup_req_valid_o && !icache_lookup_req_ready_i)
    |=> (icache_lookup_req_valid_o && $stable(icache_lookup_req_o)))
  else $error("IFU changed an I-cache request while stalled");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (fetch_entry_valid_o && !icache_lookup_resp_i.access_fault) |->
      icache_lookup_word_i == icache_lookup_resp_i.fetch_data)
  else $error("IFU predecode word differs from a successful instruction response");
`endif
endmodule
