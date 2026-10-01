// 可选后端：顺序分配和派发，独立 FU 完成，ROB 顺序退休。
module riscv32_backend
  import riscv32_pkg::*;
(
    input  logic              clk_i,
    rst_ni,
    input  decoded_uop_t      issue_uop_i,
    input  logic              issue_valid_i,
    output logic              issue_ready_o,
    input  xlen_data_t        rs1_i,
    rs2_i,
    csr_data_i,
    input  logic              csr_illegal_i,
    input  logic              issue_hold_i,
    maintenance_i,
    flush_i,
    output lsu_req_t          lsu_req_o,
    output logic              lsu_valid_o,
    input  logic              lsu_ready_i,
    input  mem_txn_id_t        lsu_req_id_i,
    input  mem_txn_id_t        lsu_result_id_i,
    input  writeback_result_t lsu_result_i,
    input  logic              lsu_result_valid_i,
    output logic              lsu_result_ready_o,
    output writeback_result_t head_o,
    output logic              head_valid_o,
    input  logic              head_ready_i,
    output execute_result_t   resolved_o,
    output logic              resolved_valid_o,
    output redirect_req_t     sequential_redirect_o,
    output logic              sequential_redirect_valid_o,
    output execute_packet_t   execute_packet_o,
    output logic              execute_valid_o,
    output logic              issue_allowed_o,
    output logic              execute_ready_o,
    output logic              busy_o,
    output logic              raw_o,
    serializing_o,
    structural_o
);
  decoded_uop_t issue_uop;
  backend_tag_t allocate_tag, execute_tag_q, alu_tag_q, head_tag;
  execute_producer_t producer_array[BACKEND_ENTRIES], source_producer_array[BACKEND_ENTRIES];
  backend_completion_t alu_completion, multiply_completion, divide_completion, memory_completion;
  logic [BACKEND_ENTRIES-1:0] cancel_vector;
  logic [BACKEND_TAG_W:0] count;
  logic allocate_ready, allocation_handshake, empty, retire_handshake, recover;
  logic scoreboard_serializing;
  logic packet_ready, packet_input_valid, dispatch_handshake, dispatch_ready;
  xlen_data_t source_a, source_b;
  execute_packet_t   prepared;
  execute_producer_t unused_producer_array[EXECUTE_PIPE_DEPTH];
  logic [31:0] multiply_a, multiply_b;
  execute_result_t alu_result, arithmetic_result;
  logic alu_selected, multiply_selected, divide_selected, memory_selected;
  logic multiply_zero, alu_handshake, multiply_handshake, divide_handshake, memory_handshake;
  logic alu_ready;
  pma_attr_t memory_attr;
  logic memory_safe, at_head, lsu_pending_q, lsu_discard_q;
  backend_tag_t lsu_tag_q, lsu_tag_array_q[LSU_ENTRIES];
  logic [LSU_ENTRIES-1:0] lsu_pending_vector_q, lsu_discard_vector_q;
  localparam int unsigned LSU_SLOT_W = (LSU_ENTRIES > 1) ? $clog2(LSU_ENTRIES) : 1;
  logic [LSU_SLOT_W-1:0] lsu_allocate_index, lsu_return_index;
  assign lsu_allocate_index = LSU_SLOT_W'(lsu_req_id_i);
  assign lsu_return_index = LSU_SLOT_W'(lsu_result_id_i);
  assign lsu_pending_q = |lsu_pending_vector_q;
  assign lsu_discard_q = |lsu_discard_vector_q;
  assign lsu_tag_q = lsu_tag_array_q[lsu_return_index];
  logic [1:0] multiply_present_vector_q, multiply_high_vector_q;
  backend_tag_t multiply_tag_array_q[2];
  logic [63:0] product;
  logic divide_pending_q, divide_available, divide_cancel;
  backend_tag_t divide_tag_q;
  muldiv_op_e divide_operation_q, divide_operation;
  logic [31:0] divide_a_q, divide_b_q, divide_a, divide_b, quotient;

  // 1. ROB 元数据与依赖读口。FENCE 在此也串行化，防止开放 FU 后越过访存。
  always_comb begin
    issue_uop             = issue_uop_i;
    issue_uop.serializing = issue_uop_i.serializing || (issue_uop_i.system_op == SYS_FENCE);
  end
  assign retire_handshake = head_valid_o && head_ready_i;
  assign recover          = resolved_valid_o && resolved_o.redirect_valid && !flush_i;
  assign busy_o           = !empty;
  riscv32_rob u_rob (
      .clk_i,
      .rst_ni,
      .flush_i,
      .allocate_uop_i  (issue_uop),
      .allocate_valid_i(allocation_handshake),
      .allocate_ready_o(allocate_ready),
      .allocate_tag_o  (allocate_tag),
      .alu_i           (alu_completion),
      .multiply_i      (multiply_completion),
      .divide_i        (divide_completion),
      .memory_i        (memory_completion),
      .recover_i       (recover),
      .recover_tag_i   (alu_tag_q),
      .cancel_vector_o (cancel_vector),
      .producer_array_o(producer_array),
      .head_o,
      .head_valid_o,
      .head_ready_i,
      .head_tag_o      (head_tag),
      .empty_o         (empty),
      .count_o         (count)
  );

  // ID/EX ALU 的即时结果覆盖尚未完成的对应条目，保留既有相邻 ALU 前递。
  always_comb begin
    for (int slot = 0; slot < BACKEND_ENTRIES; slot++) begin
      source_producer_array[slot] = producer_array[slot];
      if (alu_handshake && execute_tag_q == backend_tag_t'(slot) &&
          !alu_result.uop.exception_valid) begin
        source_producer_array[slot].forwardable = 1'b1;
        source_producer_array[slot].value       = alu_result.result;
      end
    end
  end
  riscv32_scoreboard u_scoreboard (
      .issue_uop_i     (issue_uop),
      .rs1_i,
      .rs2_i,
      .producer_array_i(source_producer_array),
      .head_tag_i      (head_tag),
      .empty_i         (empty || (count == 1 && retire_handshake)),
      .rs1_o           (source_a),
      .rs2_o           (source_b),
      .raw_o,
      .serializing_o   (scoreboard_serializing)
  );
  for (genvar i = 0; i < EXECUTE_PIPE_DEPTH; i++) begin : gen_unused_forward
    assign unused_producer_array[i] = '0;
  end
  riscv32_operand_mux u_operands (
      .decoded_uop_i                           (issue_uop),
      .rs1_value_i                             (source_a),
      .rs2_value_i                             (source_b),
      .csr_read_data_i                         (csr_data_i),
      .csr_read_illegal_i                      (csr_illegal_i),
      .pipeline_producer_i                     (unused_producer_array),
      .rs1_pipeline_forwarding_selected_i      ('0),
      .rs2_pipeline_forwarding_selected_i      ('0),
      .execute_forwarding_value_i              ('0),
      .execute_result_forwarding_value_i       ('0),
      .lsu_forwarding_value_i                  ('0),
      .writeback_forwarding_value_i            ('0),
      .rs1_execute_forwarding_selected_i       (1'b0),
      .rs2_execute_forwarding_selected_i       (1'b0),
      .rs1_execute_result_forwarding_selected_i(1'b0),
      .rs2_execute_result_forwarding_selected_i(1'b0),
      .rs1_lsu_forwarding_selected_i           (1'b0),
      .rs2_lsu_forwarding_selected_i           (1'b0),
      .rs1_writeback_forwarding_selected_i     (1'b0),
      .rs2_writeback_forwarding_selected_i     (1'b0),
      .decoded_execute_packet_o                (prepared)
  );
  assign serializing_o = scoreboard_serializing || (issue_uop.serializing && lsu_pending_q);
  assign structural_o = !allocate_ready || !packet_ready;
  assign packet_input_valid = issue_valid_i && allocate_ready && !raw_o &&
      !serializing_o && !issue_hold_i && !maintenance_i && !flush_i && !recover &&
      !sequential_redirect_valid_o;
  assign issue_ready_o = packet_ready && allocate_ready && !raw_o &&
      !serializing_o && !issue_hold_i && !maintenance_i && !flush_i && !recover &&
      !sequential_redirect_valid_o;
  assign allocation_handshake = packet_input_valid && packet_ready;
  always_ff @(posedge clk_i) begin
    if (allocation_handshake) execute_tag_q <= allocate_tag;
  end
  riscv32_id_ex_reg u_id_ex (
      .clk_i,
      .rst_ni,
      .decoded_execute_packet_i                 (prepared),
      .decoded_execute_packet_valid_i           (packet_input_valid),
      .decoded_execute_packet_ready_o           (packet_ready),
      .execute_packet_o,
      .multiply_operand_a_o                     (multiply_a),
      .multiply_operand_b_o                     (multiply_b),
      .execute_packet_valid_o                   (execute_valid_o),
      .execute_packet_ready_i                   (dispatch_handshake),
      .execute_forwardable_producer_present_o   (),
      .execute_blocking_producer_present_o      (),
      .execute_serializing_instruction_present_o(),
      .flush_i                                  (flush_i || recover || sequential_redirect_valid_o)
  );

  // 2. 派发：FU 独立接收。store/MMIO 只可由队首授权；队首当拍退休可授权下一项。
  assign issue_allowed_o = !flush_i && !recover && !maintenance_i;
  assign memory_selected = execute_packet_o.uop.fu_type == FU_LSU;
  assign multiply_selected = execute_packet_o.uop.fu_type == FU_MULDIV &&
      execute_packet_o.uop.muldiv_op <= MD_MULHU && !execute_packet_o.uop.exception_valid;
  assign divide_selected = execute_packet_o.uop.fu_type == FU_MULDIV &&
      execute_packet_o.uop.muldiv_op > MD_MULHU && !execute_packet_o.uop.exception_valid;
  assign multiply_zero = (multiply_a == 0) || (multiply_b == 0);
  assign alu_selected = !memory_selected && !divide_selected &&
                        (!multiply_selected || multiply_zero);
  assign at_head = (execute_tag_q == head_tag) ||
      (retire_handshake && execute_tag_q == backend_tag_t'(head_tag + 1'b1));
  riscv32_pma u_memory_attributes (
      .lookup_addr_i(lsu_req_o.effective_addr[31:0]),
      .memory_attr_o(memory_attr)
  );
  assign memory_safe = at_head || (BACKEND_LOAD_OVERLAP &&
      execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD &&
      memory_attr.readable && memory_attr.cacheable && memory_attr.idempotent);
  always_comb begin
    dispatch_ready = alu_ready;
    if (multiply_selected && !multiply_zero) dispatch_ready = 1'b1;
    if (divide_selected) dispatch_ready = !divide_pending_q || divide_available;
    if (memory_selected) dispatch_ready = memory_safe && ((LSU_ENTRIES > 1) || !lsu_discard_q) && lsu_ready_i;
  end
  assign execute_ready_o = dispatch_ready && issue_allowed_o;
  assign dispatch_handshake = execute_valid_o && issue_allowed_o && dispatch_ready;
  assign alu_handshake = dispatch_handshake && alu_selected;
  assign multiply_handshake = dispatch_handshake && multiply_selected && !multiply_zero;
  assign divide_handshake = dispatch_handshake && divide_selected;
  assign memory_handshake = lsu_valid_o && lsu_ready_i;
  assign lsu_valid_o = execute_valid_o && issue_allowed_o && memory_selected &&
                       memory_safe && ((LSU_ENTRIES > 1) || !lsu_discard_q);

  // 3. 共用现有 ALU/AGU/CSR 电路，不实例化旧的乘除调度通路。
  riscv32_exu #(
      .EXTERNAL_MULDIV(1'b1)
  ) u_alu (
      .clk_i,
      .rst_ni,
      .flush_i                       (flush_i || recover),
      .execute_packet_i              (execute_packet_o),
      .multiply_operand_a_i          (multiply_a),
      .multiply_operand_b_i          (multiply_b),
      .execute_packet_valid_i        (execute_valid_o),
      .execute_packet_issue_allowed_i(issue_allowed_o),
      .execute_packet_ready_o        (),
      .exu_result_o                  (arithmetic_result),
      .exu_result_valid_o            (),
      .muldiv_result_available_o     (),
      .execute_forwarding_value_o    (),
      .pipeline_busy_o               (),
      .pipeline_producer_o           (),
      .exu_result_ready_i            (1'b1),
      .lsu_req_o,
      .lsu_req_valid_o               (),
      .lsu_req_ready_i               (lsu_ready_i),
      .sequential_redirect_o         (),
      .sequential_redirect_valid_o   ()
  );
  always_comb begin
    alu_result = arithmetic_result;
    if (multiply_selected && multiply_zero) alu_result.result = '0;
  end
  always_ff @(posedge clk_i) begin
    if (alu_handshake) alu_tag_q <= execute_tag_q;
  end
  riscv32_ex_result_reg u_alu_result (
      .clk_i,
      .rst_ni,
      .executed_result_i      (alu_result),
      .executed_result_valid_i(alu_handshake),
      .executed_result_ready_o(alu_ready),
      .resolved_result_o      (resolved_o),
      .resolved_result_valid_o(resolved_valid_o),
      .resolved_result_ready_i(1'b1),
      .flush_i                (flush_i || recover)
  );

  // 非分支预测纠错在顺序派发边界进行，此时没有更年轻的已派发指令。
  always_comb begin
    sequential_redirect_o = '0;
    sequential_redirect_o.target_pc = execute_packet_o.uop.pc + program_counter_t'(INSTRUCTION_BYTES);
    sequential_redirect_o.source_pc = execute_packet_o.uop.pc;
    sequential_redirect_o.reason = REDIRECT_BRANCH_MISPREDICT;
    sequential_redirect_o.flush_inclusive = 1'b0;
  end
  assign sequential_redirect_valid_o = dispatch_handshake &&
      execute_packet_o.uop.fu_type != FU_BRANCH && !execute_packet_o.uop.exception_valid &&
      execute_packet_o.uop.prediction.predicted_taken &&
      execute_packet_o.uop.prediction.predicted_target != sequential_redirect_o.target_pc;

  // 4. 乘法只保存两个算法级的 tag/valid/高半选择；结果不再等老除法或访存。
  riscv32_mul u_mul (
      .clk_i,
      .partial_products_write_i(multiply_handshake),
      .compressed_sum_write_i  (multiply_present_vector_q[0]),
      .operation_i             (execute_packet_o.uop.muldiv_op),
      .operand_a_i             (multiply_a),
      .operand_b_i             (multiply_b),
      .product_o               (product)
  );
  always_ff @(posedge clk_i) begin
    if (multiply_handshake) begin
      multiply_tag_array_q[0]   <= execute_tag_q;
      multiply_high_vector_q[0] <= execute_packet_o.uop.muldiv_op != MD_MUL;
    end
    if (multiply_present_vector_q[0]) begin
      multiply_tag_array_q[1]   <= multiply_tag_array_q[0];
      multiply_high_vector_q[1] <= multiply_high_vector_q[0];
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) multiply_present_vector_q <= '0;
    else if (flush_i) multiply_present_vector_q <= '0;
    else begin
      multiply_present_vector_q[0] <= multiply_handshake;
      multiply_present_vector_q[1] <= multiply_present_vector_q[0] && !cancel_vector[multiply_tag_array_q[0]];
    end
  end

  // 5. 除法输入空时直通，迭代时由本地上下文保持，释放 ID/EX 给其他 FU。
  assign divide_operation = divide_pending_q ? divide_operation_q : execute_packet_o.uop.muldiv_op;
  assign divide_a         = divide_pending_q ? divide_a_q : execute_packet_o.source_a_value;
  assign divide_b         = divide_pending_q ? divide_b_q : execute_packet_o.source_b_value;
  assign divide_cancel    = flush_i || (divide_pending_q && cancel_vector[divide_tag_q]);
  riscv32_div u_div (
      .clk_i,
      .rst_ni,
      .flush_i           (divide_cancel),
      .operation_valid_i (divide_pending_q || divide_handshake),
      .operation_i       (divide_operation),
      .operand_a_i       (divide_a),
      .operand_b_i       (divide_b),
      .result_o          (quotient),
      .result_available_o(divide_available),
      .result_ready_i    (1'b1)
  );
  always_ff @(posedge clk_i) begin
    if (divide_handshake) begin
      divide_tag_q       <= execute_tag_q;
      divide_operation_q <= execute_packet_o.uop.muldiv_op;
      divide_a_q         <= execute_packet_o.source_a_value;
      divide_b_q         <= execute_packet_o.source_b_value;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) divide_pending_q <= 1'b0;
    else if (divide_cancel) divide_pending_q <= 1'b0;
    else begin
      if (divide_pending_q && divide_available) divide_pending_q <= 1'b0;
      // 老除法最后拍可接收新上下文；新操作下一拍从 IDLE 开始。
      if (divide_handshake) divide_pending_q <= divide_pending_q || !divide_available;
    end
  end

  // 6. LSU 槽位到 ROB 身份的映射。取消只标记丢弃，迟到响应排空后才复用槽位。
  assign lsu_result_ready_o = 1'b1;
  always_ff @(posedge clk_i) begin
    if (memory_handshake) lsu_tag_array_q[lsu_allocate_index] <= execute_tag_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_pending_vector_q <= '0;
      lsu_discard_vector_q <= '0;
    end else begin
      for (int slot = 0; slot < LSU_ENTRIES; slot++) begin
        if (lsu_pending_vector_q[slot] &&
            (flush_i || cancel_vector[lsu_tag_array_q[slot]]))
          lsu_discard_vector_q[slot] <= 1'b1;
      end
      if (lsu_result_valid_i) begin
        lsu_pending_vector_q[lsu_return_index] <= 1'b0;
        lsu_discard_vector_q[lsu_return_index] <= 1'b0;
      end
      if (memory_handshake) begin
        lsu_pending_vector_q[lsu_allocate_index] <= 1'b1;
        lsu_discard_vector_q[lsu_allocate_index] <= 1'b0;
      end
    end
  end

  // 7. 带身份返回 ROB：ALU 结果级与 MUL 可由队首旁路退休；四路均保留 Issue 前递。
  always_comb begin
    alu_completion                 = '0;
    alu_completion.valid           = resolved_valid_o;
    alu_completion.tag             = alu_tag_q;
    alu_completion.value           = resolved_o.result;
    alu_completion.next_pc         = resolved_o.next_pc;
    alu_completion.csr_wdata       = resolved_o.csr_wdata;
    alu_completion.exception_valid = resolved_o.uop.exception_valid;
    alu_completion.exception_cause = resolved_o.uop.exception_cause;
    alu_completion.exception_tval  = resolved_o.uop.exception_tval;
  end
  always_comb begin
    multiply_completion       = '0;
    multiply_completion.valid = multiply_present_vector_q[1];
    multiply_completion.tag   = multiply_tag_array_q[1];
    multiply_completion.value = multiply_high_vector_q[1] ? product[63:32] : product[31:0];
  end
  always_comb begin
    divide_completion       = '0;
    divide_completion.valid = (divide_pending_q || divide_handshake) && divide_available;
    divide_completion.tag   = divide_pending_q ? divide_tag_q : execute_tag_q;
    divide_completion.value = quotient;
  end
  always_comb begin
    memory_completion                 = '0;
    memory_completion.valid           = lsu_result_valid_i && lsu_pending_vector_q[lsu_return_index] &&
        !lsu_discard_vector_q[lsu_return_index];
    memory_completion.tag             = lsu_tag_q;
    memory_completion.value           = lsu_result_i.result;
    memory_completion.next_pc         = lsu_result_i.next_pc;
    memory_completion.memory_addr     = lsu_result_i.memory_addr;
    memory_completion.memory_rdata    = lsu_result_i.memory_rdata;
    memory_completion.memory_wdata    = lsu_result_i.memory_wdata;
    memory_completion.memory_wmask    = lsu_result_i.memory_wmask;
    memory_completion.exception_valid = lsu_result_i.uop.exception_valid;
    memory_completion.exception_cause = lsu_result_i.uop.exception_cause;
    memory_completion.exception_tval  = lsu_result_i.uop.exception_tval;
  end

`ifdef NPC_ENABLE_SIM_MONITOR
  // 仅观察器需要遍历数组；独立 FU 直接连接 ROB，避免数组归并出虚假反馈。
  backend_completion_t completion_array[BACKEND_PORTS];
  assign completion_array[0] = alu_completion;
  assign completion_array[1] = multiply_completion;
  assign completion_array[2] = divide_completion;
  assign completion_array[3] = memory_completion;
  longint unsigned cycles_q, dispatches_q, div_overlap_q, load_overlap_q;
  longint unsigned multi_complete_q, discarded_loads_q, head_wait_q, occupancy_sum_q;
  longint unsigned mul_dispatch_q, div_dispatch_q, memory_dispatch_q;
  longint unsigned mul_during_div_q, load_during_div_q, mul_during_load_q;
  longint unsigned consecutive_mul_q, out_of_order_completions_q;
  logic previous_mul_q;
  int completions, out_of_order_completions;
  always_comb begin
    completions = 0;
    out_of_order_completions = 0;
    for (int port = 0; port < BACKEND_PORTS; port++) begin
      if (completion_array[port].valid && !flush_i &&
          !cancel_vector[completion_array[port].tag]) begin
        completions++;
        if (completion_array[port].tag != head_tag) out_of_order_completions++;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycles_q                   <= 0;
      dispatches_q               <= 0;
      div_overlap_q              <= 0;
      load_overlap_q             <= 0;
      multi_complete_q           <= 0;
      discarded_loads_q          <= 0;
      head_wait_q                <= 0;
      occupancy_sum_q            <= 0;
      mul_dispatch_q             <= 0;
      div_dispatch_q             <= 0;
      memory_dispatch_q          <= 0;
      mul_during_div_q           <= 0;
      load_during_div_q          <= 0;
      mul_during_load_q          <= 0;
      consecutive_mul_q          <= 0;
      out_of_order_completions_q <= 0;
      previous_mul_q             <= 1'b0;
    end else begin
      previous_mul_q <= multiply_handshake;
      if (multiply_handshake) mul_dispatch_q <= mul_dispatch_q + 1;
      if (divide_handshake) div_dispatch_q <= div_dispatch_q + 1;
      if (memory_handshake) memory_dispatch_q <= memory_dispatch_q + 1;
      if (multiply_handshake && divide_pending_q && !divide_available)
        mul_during_div_q <= mul_during_div_q + 1;
      if (memory_handshake && execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD &&
          divide_pending_q && !divide_available)
        load_during_div_q <= load_during_div_q + 1;
      if (multiply_handshake && lsu_pending_q && !lsu_result_valid_i)
        mul_during_load_q <= mul_during_load_q + 1;
      if (multiply_handshake && previous_mul_q) consecutive_mul_q <= consecutive_mul_q + 1;
      out_of_order_completions_q <= out_of_order_completions_q + 64'(out_of_order_completions);
      cycles_q                   <= cycles_q + 1;
      occupancy_sum_q            <= occupancy_sum_q + 64'(count);
      if (dispatch_handshake) dispatches_q <= dispatches_q + 1;
      if (dispatch_handshake && divide_pending_q && !divide_available)
        div_overlap_q <= div_overlap_q + 1;
      if (memory_handshake && !at_head) load_overlap_q <= load_overlap_q + 1;
      if (completions > 1) multi_complete_q <= multi_complete_q + 1;
      if (lsu_result_valid_i && lsu_discard_vector_q[lsu_return_index]) discarded_loads_q <= discarded_loads_q + 1;
      if (!empty && !head_valid_o) head_wait_q <= head_wait_q + 1;
    end
  end
  final
    $display(
        "NPC ROB: entries=%0d load_overlap=%0d cycles=%0d dispatched=%0d div_overlap=%0d speculative_load=%0d multi_complete=%0d discarded_load=%0d head_wait=%0d occupancy_sum=%0d",
        BACKEND_ENTRIES,
        BACKEND_LOAD_OVERLAP,
        cycles_q,
        dispatches_q,
        div_overlap_q,
        load_overlap_q,
        multi_complete_q,
        discarded_loads_q,
        head_wait_q,
        occupancy_sum_q
    );
  final
    $display(
        "NPC FU: mul=%0d div=%0d memory=%0d mul_during_div=%0d load_during_div=%0d mul_during_load=%0d consecutive_mul=%0d out_of_order_completions=%0d",
        mul_dispatch_q,
        div_dispatch_q,
        memory_dispatch_q,
        mul_during_div_q,
        load_during_div_q,
        mul_during_load_q,
        consecutive_mul_q,
        out_of_order_completions_q
    );
`endif

`ifndef SYNTHESIS
  initial assert (XLEN == 32 && MULDIV_ENABLE && MUL_PIPELINE_ENABLE);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    memory_handshake && !at_head |-> BACKEND_LOAD_OVERLAP &&
      execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD &&
      memory_attr.readable && memory_attr.cacheable && memory_attr.idempotent);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (flush_i || recover) |-> !lsu_valid_o && !dispatch_handshake && !allocation_handshake);
  assert property (@(posedge clk_i) disable iff (!rst_ni) lsu_result_valid_i |-> lsu_pending_vector_q[lsu_return_index]);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lsu_result_valid_i && lsu_discard_vector_q[lsu_return_index] |-> !memory_completion.valid);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    head_valid_o && head_o.uop.serializing |-> count == 1 && !execute_valid_o);
`endif
endmodule
