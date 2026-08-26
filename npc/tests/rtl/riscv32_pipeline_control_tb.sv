module riscv32_pipeline_control_tb;
  import riscv32_addr_map_pkg::*;
  import riscv32_pkg::*;

  localparam program_counter_t IFU_TEST_START_PC = program_counter_t'('h8000_0000);

  logic                clk;
  logic                rst_ni;

  redirect_req_t       ifu_redirect_req;
  logic                ifu_redirect_req_valid;
  icache_lookup_req_t  icache_lookup_req;
  logic                icache_lookup_req_valid;
  logic                icache_lookup_req_ready;
  icache_lookup_resp_t icache_lookup_resp;
  logic                icache_lookup_resp_valid;
  logic                icache_lookup_resp_ready;
  fetch_entry_t        ifu_fetch_entry;
  logic                ifu_fetch_entry_valid;
  logic                ifu_fetch_entry_ready;

  fetch_entry_t        fetch_buffer_input_entry;
  logic                fetch_buffer_input_valid;
  logic                fetch_buffer_input_ready;
  fetch_entry_t        fetch_buffer_output_entry;
  logic                fetch_buffer_output_valid;
  logic                fetch_buffer_output_ready;
  logic                fetch_buffer_flush;

  program_counter_t    predictor_lookup_pc;
  logic                predictor_lookup_request_valid;
  logic                predictor_lookup_request_ready;
  branch_prediction_t  predictor_lookup_prediction;
  program_counter_t    predictor_lookup_next_pc;
  logic                predictor_lookup_response_valid;
  logic                predictor_lookup_response_ready;
  branch_prediction_t  ifu_predictor_prediction;
  program_counter_t    predictor_resolved_control_flow_pc;
  program_counter_t    predictor_resolved_control_flow_target;
  xlen_data_t          predictor_resolved_control_flow_imm;
  control_flow_op_e    predictor_resolved_control_flow_op;
  arch_reg_idx_t       predictor_resolved_control_flow_rs1;
  arch_reg_idx_t       predictor_resolved_control_flow_rd;
  logic                predictor_resolved_control_flow_occurred;
  logic                predictor_resolved_control_flow_taken;
  logic                predictor_invalidate;

  execute_packet_t     decoded_execute_packet;
  logic                decoded_execute_packet_valid;
  logic                decoded_execute_packet_ready;
  execute_packet_t     execute_packet;
  logic                execute_packet_valid;
  logic                execute_packet_ready;
  logic                decode_execute_flush;

  writeback_result_t   completion_result;
  logic                completion_result_valid;
  logic                completion_result_ready;
  writeback_result_t   writeback_result;
  logic                writeback_result_valid;
  logic                writeback_result_ready;
  logic                writeback_flush;

  commit_t             staged_commit;
  logic                staged_commit_valid;
  redirect_req_t       staged_trap_redirect;
  logic                staged_trap_redirect_valid;

  decoded_uop_t        hazard_decoded_uop;
  logic                hazard_decoded_uop_valid;
  decoded_uop_t        hazard_execute_uop;
  logic                hazard_execute_uop_valid;
  writeback_result_t   hazard_writeback_result;
  logic                hazard_writeback_result_valid;
  logic                lsu_busy;
  logic                lsu_pending_writes_rd;
  arch_reg_idx_t       lsu_pending_rd;
  logic                lsu_forwarding_available;
  logic                frontend_redirect_applied;
  logic                commit_redirect_occurred;
  logic                decode_accept_allowed;
  logic                execute_issue_allowed;
  logic                hazard_decode_execute_flush;
  logic                hazard_writeback_flush;
  logic                raw_hazard_present;
  logic                serializing_hazard_present;
  logic                structural_hazard_present;
  logic                execute_forwarding_available;
  logic                execute_result_valid;
  logic                execute_result_ready;
  logic                execute_result_writes_rd;
  arch_reg_idx_t       execute_result_rd;
  logic                execute_result_forwarding_available;
  logic                execute_result_serializing;
  logic                writeback_forwarding_available;
  logic                rs1_execute_forwarding_selected;
  logic                rs1_execute_result_forwarding_selected;
  logic                rs1_lsu_forwarding_selected;
  logic                rs1_writeback_forwarding_selected;
  logic                rs2_execute_forwarding_selected;
  logic                rs2_execute_result_forwarding_selected;
  logic                rs2_lsu_forwarding_selected;
  logic                rs2_writeback_forwarding_selected;

  riscv32_ifu #(
      .PC_START(IFU_TEST_START_PC)
  ) u_ifu (
      .clk_i                         (clk),
      .rst_ni                        (rst_ni),
      .redirect_req_i                (ifu_redirect_req),
      .redirect_req_valid_i          (ifu_redirect_req_valid),
      .next_pc_predictor_prediction_i(ifu_predictor_prediction),
      .icache_lookup_req_o           (icache_lookup_req),
      .icache_lookup_req_valid_o     (icache_lookup_req_valid),
      .icache_lookup_req_ready_i     (icache_lookup_req_ready),
      .icache_lookup_resp_i          (icache_lookup_resp),
      .icache_lookup_resp_valid_i    (icache_lookup_resp_valid),
      .icache_lookup_resp_ready_o    (icache_lookup_resp_ready),
      .fetch_entry_o                 (ifu_fetch_entry),
      .fetch_entry_valid_o           (ifu_fetch_entry_valid),
      .fetch_entry_ready_i           (ifu_fetch_entry_ready)
  );

  riscv32_decode_execute_stage u_decode_execute_stage (
      .clk_i                         (clk),
      .rst_ni                        (rst_ni),
      .decoded_execute_packet_i      (decoded_execute_packet),
      .decoded_execute_packet_valid_i(decoded_execute_packet_valid),
      .decoded_execute_packet_ready_o(decoded_execute_packet_ready),
      .execute_packet_o              (execute_packet),
      .execute_packet_valid_o        (execute_packet_valid),
      .execute_packet_ready_i        (execute_packet_ready),
      .flush_i                       (decode_execute_flush)
  );

  riscv32_fetch_buffer #(
      .ENTRY_COUNT(2)
  ) u_fetch_buffer (
      .clk_i                  (clk),
      .rst_ni                 (rst_ni),
      .ifu_fetch_entry_i      (fetch_buffer_input_entry),
      .ifu_fetch_entry_valid_i(fetch_buffer_input_valid),
      .ifu_fetch_entry_ready_o(fetch_buffer_input_ready),
      .idu_fetch_entry_o      (fetch_buffer_output_entry),
      .idu_fetch_entry_valid_o(fetch_buffer_output_valid),
      .idu_fetch_entry_ready_i(fetch_buffer_output_ready),
      .flush_i                (fetch_buffer_flush)
  );

  riscv32_fetch_control_flow_predictor u_fetch_control_flow_predictor (
      .clk_i                           (clk),
      .rst_ni                          (rst_ni),
      .lookup_request_pc_i             (predictor_lookup_pc),
      .lookup_request_valid_i          (predictor_lookup_request_valid),
      .lookup_request_ready_o          (predictor_lookup_request_ready),
      .lookup_prediction_o             (predictor_lookup_prediction),
      .lookup_next_pc_o                (predictor_lookup_next_pc),
      .lookup_response_valid_o         (predictor_lookup_response_valid),
      .lookup_response_ready_i         (predictor_lookup_response_ready),
      .resolved_control_flow_pc_i      (predictor_resolved_control_flow_pc),
      .resolved_control_flow_target_i  (predictor_resolved_control_flow_target),
      .resolved_control_flow_imm_i     (predictor_resolved_control_flow_imm),
      .resolved_control_flow_op_i      (predictor_resolved_control_flow_op),
      .resolved_control_flow_rs1_i     (predictor_resolved_control_flow_rs1),
      .resolved_control_flow_rd_i      (predictor_resolved_control_flow_rd),
      .resolved_control_flow_occurred_i(predictor_resolved_control_flow_occurred),
      .resolved_control_flow_taken_i   (predictor_resolved_control_flow_taken),
      .invalidate_i                    (predictor_invalidate)
  );

  riscv32_writeback_stage u_writeback_stage (
      .clk_i                    (clk),
      .rst_ni                   (rst_ni),
      .completion_result_i      (completion_result),
      .completion_result_valid_i(completion_result_valid),
      .completion_result_ready_o(completion_result_ready),
      .writeback_result_o       (writeback_result),
      .writeback_result_valid_o (writeback_result_valid),
      .writeback_result_ready_i (writeback_result_ready),
      .flush_i                  (writeback_flush)
  );

  riscv32_commit u_commit (
      .writeback_result_i      (writeback_result),
      .writeback_result_valid_i(writeback_result_valid),
      .writeback_result_ready_o(),
      .commit_o                (staged_commit),
      .commit_valid_o          (staged_commit_valid),
      .gpr_write_data_o        (),
      .gpr_write_addr_o        (),
      .gpr_write_enable_o      ()
  );

  riscv32_trap_controller u_trap_controller (
      .commit_i            (staged_commit),
      .commit_valid_i      (staged_commit_valid),
      .mtvec_i             (program_counter_t'(64'h8000_0100)),
      .mepc_i              ('0),
      .trap_valid_o        (),
      .trap_pc_o           (),
      .trap_cause_o        (),
      .trap_tval_o         (),
      .mret_valid_o        (),
      .redirect_req_o      (staged_trap_redirect),
      .redirect_req_valid_o(staged_trap_redirect_valid)
  );

  riscv32_pipeline_hazard_controller u_pipeline_hazard_controller (
      .clk_i                                   (clk),
      .rst_ni                                  (rst_ni),
      .decoded_uop_valid_i                     (hazard_decoded_uop_valid),
      .decoded_uses_rs1_i                      (hazard_decoded_uop.uses_rs1),
      .decoded_rs1_i                           (hazard_decoded_uop.rs1),
      .decoded_uses_rs2_i                      (hazard_decoded_uop.uses_rs2),
      .decoded_rs2_i                           (hazard_decoded_uop.rs2),
      .decoded_serializing_i                   (hazard_decoded_uop.serializing),
      .execute_uop_valid_i                     (hazard_execute_uop_valid),
      .execute_writes_rd_i                     (hazard_execute_uop.writes_rd),
      .execute_rd_i                            (hazard_execute_uop.rd),
      .execute_serializing_i                   (hazard_execute_uop.serializing),
      .execute_forwarding_available_i          (execute_forwarding_available),
      .execute_result_valid_i                  (execute_result_valid),
      .execute_result_ready_i                  (execute_result_ready),
      .execute_result_writes_rd_i              (execute_result_writes_rd),
      .execute_result_rd_i                     (execute_result_rd),
      .execute_result_forwarding_available_i   (execute_result_forwarding_available),
      .execute_result_serializing_i            (execute_result_serializing),
      .writeback_result_valid_i                (hazard_writeback_result_valid),
      .writeback_writes_rd_i                   (hazard_writeback_result.uop.writes_rd),
      .writeback_rd_i                          (hazard_writeback_result.uop.rd),
      .writeback_serializing_i                 (hazard_writeback_result.uop.serializing),
      .writeback_forwarding_available_i        (writeback_forwarding_available),
      .lsu_busy_i                              (lsu_busy),
      .lsu_pending_writes_rd_i                 (lsu_pending_writes_rd),
      .lsu_pending_rd_i                        (lsu_pending_rd),
      .lsu_forwarding_available_i              (lsu_forwarding_available),
      .execute_redirect_present_i              (1'b0),
      .frontend_redirect_applied_i             (frontend_redirect_applied),
      .commit_redirect_occurred_i              (commit_redirect_occurred),
      .decode_accept_allowed_o                 (decode_accept_allowed),
      .execute_issue_allowed_o                 (execute_issue_allowed),
      .decode_execute_flush_o                  (hazard_decode_execute_flush),
      .writeback_flush_o                       (hazard_writeback_flush),
      .raw_hazard_present_o                    (raw_hazard_present),
      .serializing_hazard_present_o            (serializing_hazard_present),
      .structural_hazard_present_o             (structural_hazard_present),
      .rs1_execute_forwarding_selected_o       (rs1_execute_forwarding_selected),
      .rs1_execute_result_forwarding_selected_o(rs1_execute_result_forwarding_selected),
      .rs1_lsu_forwarding_selected_o           (rs1_lsu_forwarding_selected),
      .rs1_writeback_forwarding_selected_o     (rs1_writeback_forwarding_selected),
      .rs2_execute_forwarding_selected_o       (rs2_execute_forwarding_selected),
      .rs2_execute_result_forwarding_selected_o(rs2_execute_result_forwarding_selected),
      .rs2_lsu_forwarding_selected_o           (rs2_lsu_forwarding_selected),
      .rs2_writeback_forwarding_selected_o     (rs2_writeback_forwarding_selected)
  );

  always #5 clk = ~clk;

  function automatic execute_packet_t make_execute_packet(input program_counter_t pc,
                                                          input arch_reg_idx_t destination_register,
                                                          input xlen_data_t source_value);
    execute_packet_t packet;
    packet               = '0;
    packet.uop.pc        = pc;
    packet.uop.rd        = destination_register;
    packet.uop.writes_rd = destination_register != '0;
    packet.rs1_value     = source_value;
    return packet;
  endfunction

  function automatic writeback_result_t make_writeback_result(
      input program_counter_t pc, input arch_reg_idx_t destination_register,
      input xlen_data_t result);
    writeback_result_t writeback;
    writeback               = '0;
    writeback.uop.pc        = pc;
    writeback.uop.rd        = destination_register;
    writeback.uop.writes_rd = destination_register != '0;
    writeback.result        = result;
    return writeback;
  endfunction

  function automatic execute_result_t make_execute_result(input program_counter_t pc,
                                                          input arch_reg_idx_t destination_register,
                                                          input xlen_data_t result);
    execute_result_t execute_result;
    execute_result               = '0;
    execute_result.uop.pc        = pc;
    execute_result.uop.rd        = destination_register;
    execute_result.uop.writes_rd = destination_register != '0;
    execute_result.result        = result;
    execute_result.next_pc       = pc + program_counter_t'(INSTRUCTION_BYTES);
    return execute_result;
  endfunction

  function automatic icache_lookup_resp_t make_lookup_response(input icache_lookup_req_t request,
                                                               input instruction_t instruction);
    icache_lookup_resp_t response;
    response              = '0;
    response.fetch_addr   = request.fetch_addr;
    response.fetch_data   = instruction;
    response.frontend_tag = request.frontend_tag;
    response.fetch_epoch  = request.fetch_epoch;
    return response;
  endfunction

  task automatic clear_ifu_inputs;
    ifu_redirect_req         = '0;
    ifu_redirect_req_valid   = 1'b0;
    icache_lookup_req_ready  = 1'b0;
    icache_lookup_resp       = '0;
    icache_lookup_resp_valid = 1'b0;
    ifu_fetch_entry_ready    = 1'b0;
    ifu_predictor_prediction = '0;
  endtask

  task automatic clear_hazard_inputs;
    hazard_decoded_uop                  = '0;
    hazard_decoded_uop_valid            = 1'b0;
    hazard_execute_uop                  = '0;
    hazard_execute_uop_valid            = 1'b0;
    hazard_writeback_result             = '0;
    hazard_writeback_result_valid       = 1'b0;
    lsu_busy                            = 1'b0;
    lsu_pending_writes_rd               = 1'b0;
    lsu_pending_rd                      = '0;
    lsu_forwarding_available            = 1'b0;
    frontend_redirect_applied           = 1'b0;
    commit_redirect_occurred            = 1'b0;
    execute_forwarding_available        = 1'b0;
    execute_result_valid                = 1'b0;
    execute_result_ready                = 1'b1;
    execute_result_writes_rd            = 1'b0;
    execute_result_rd                   = '0;
    execute_result_forwarding_available = 1'b0;
    execute_result_serializing          = 1'b0;
    writeback_forwarding_available      = 1'b0;
  endtask

  function automatic fetch_entry_t make_fetch_entry(input program_counter_t pc,
                                                    input instruction_t instruction);
    fetch_entry_t entry;
    entry             = '0;
    entry.pc          = pc;
    entry.instruction = instruction;
    return entry;
  endfunction

  task automatic clear_fetch_buffer_inputs;
    fetch_buffer_input_entry  = '0;
    fetch_buffer_input_valid  = 1'b0;
    fetch_buffer_output_ready = 1'b0;
    fetch_buffer_flush        = 1'b0;
  endtask

  task automatic clear_predictor_inputs;
    predictor_lookup_pc                      = '0;
    predictor_lookup_request_valid           = 1'b0;
    predictor_lookup_response_ready          = 1'b1;
    predictor_resolved_control_flow_pc       = '0;
    predictor_resolved_control_flow_target   = '0;
    predictor_resolved_control_flow_imm      = '0;
    predictor_resolved_control_flow_op       = CF_NONE;
    predictor_resolved_control_flow_rs1      = '0;
    predictor_resolved_control_flow_rd       = '0;
    predictor_resolved_control_flow_occurred = 1'b0;
    predictor_resolved_control_flow_taken    = 1'b0;
    predictor_invalidate                     = 1'b0;
  endtask

  task automatic query_predictor(input program_counter_t lookup_pc);
    @(negedge clk);
    predictor_lookup_pc            = lookup_pc;
    predictor_lookup_request_valid = 1'b1;
    #1;
    assert (predictor_lookup_request_ready)
    else $fatal(1, "predictor did not accept a lookup while its response slot was free");
    @(posedge clk);
    @(negedge clk);
    predictor_lookup_request_valid = 1'b0;
    #1;
    assert (predictor_lookup_response_valid)
    else $fatal(1, "predictor did not publish the registered lookup response");
  endtask

  task automatic check_fetch_control_flow_predictor;
    localparam program_counter_t JAL_PC = program_counter_t'('h8000_0100);
    localparam program_counter_t BRANCH_PC = program_counter_t'('h8000_0200);
    localparam program_counter_t RETURN_PC = program_counter_t'('h8000_0280);
    localparam program_counter_t CALL_PC = program_counter_t'('h8000_0300);
    localparam program_counter_t JAL_TARGET = JAL_PC + program_counter_t'(8);
    localparam program_counter_t BRANCH_TARGET = BRANCH_PC + program_counter_t'(8);

    // 冷BTB只能给出顺序PC。结果在请求握手后的下一拍出现，而不是组合反馈到请求PC。
    query_predictor(JAL_PC);
    assert (!predictor_lookup_prediction.predicted_taken &&
            (predictor_lookup_next_pc == JAL_PC + program_counter_t'(INSTRUCTION_BYTES)))
    else $fatal(1, "cold BTB lookup did not select the sequential PC");

    // 响应反压期间预测payload必须保持稳定。
    predictor_lookup_response_ready = 1'b0;
    @(posedge clk);
    #1;
    assert (predictor_lookup_response_valid &&
            (predictor_lookup_next_pc == JAL_PC + program_counter_t'(INSTRUCTION_BYTES)))
    else $fatal(1, "predictor response changed while backpressured");
    @(negedge clk);
    predictor_lookup_response_ready          = 1'b1;

    // EX解析JAL后训练BTB，随后查询同一PC应直接采用目标地址。
    predictor_resolved_control_flow_pc       = JAL_PC;
    predictor_resolved_control_flow_target   = JAL_TARGET;
    predictor_resolved_control_flow_op       = CF_JAL;
    predictor_resolved_control_flow_rd       = arch_reg_idx_t'(0);
    predictor_resolved_control_flow_occurred = 1'b1;
    predictor_resolved_control_flow_taken    = 1'b1;
    @(posedge clk);
    @(negedge clk);
    predictor_resolved_control_flow_occurred = 1'b0;
    query_predictor(JAL_PC);
    assert (predictor_lookup_prediction.predicted_taken &&
            (predictor_lookup_prediction.predicted_target == JAL_TARGET) &&
            (predictor_lookup_next_pc == JAL_TARGET))
    else $fatal(1, "trained JAL BTB entry did not predict its target");

    // 条件分支BTB和BHT分别训练；BHT写口晚一级，因此等待训练真正落入数组后再查询。
    predictor_resolved_control_flow_pc       = BRANCH_PC;
    predictor_resolved_control_flow_target   = BRANCH_TARGET;
    predictor_resolved_control_flow_op       = CF_BRANCH;
    predictor_resolved_control_flow_rd       = '0;
    predictor_resolved_control_flow_occurred = 1'b1;
    predictor_resolved_control_flow_taken    = 1'b1;
    @(posedge clk);
    @(negedge clk);
    predictor_resolved_control_flow_occurred = 1'b0;
    @(posedge clk);
    query_predictor(BRANCH_PC);
    assert (predictor_lookup_prediction.predicted_taken &&
            (predictor_lookup_prediction.predicted_target == BRANCH_TARGET))
    else $fatal(1, "trained BHT entry did not predict the branch taken");

    predictor_resolved_control_flow_occurred = 1'b1;
    predictor_resolved_control_flow_taken    = 1'b0;
    @(posedge clk);
    @(negedge clk);
    predictor_resolved_control_flow_occurred = 1'b0;
    @(posedge clk);
    query_predictor(BRANCH_PC);
    assert (!predictor_lookup_prediction.predicted_taken &&
            (predictor_lookup_next_pc == BRANCH_PC + program_counter_t'(INSTRUCTION_BYTES)))
    else $fatal(1, "BHT saturating counter did not learn the not-taken outcome");

    // 先训练return类型，再解析call压入PC+4；查询return时应优先使用RAS栈顶。
    predictor_resolved_control_flow_pc       = RETURN_PC;
    predictor_resolved_control_flow_target   = program_counter_t'('h8000_0500);
    predictor_resolved_control_flow_op       = CF_JALR;
    predictor_resolved_control_flow_rs1      = arch_reg_idx_t'(1);
    predictor_resolved_control_flow_rd       = arch_reg_idx_t'(0);
    predictor_resolved_control_flow_occurred = 1'b1;
    predictor_resolved_control_flow_taken    = 1'b1;
    @(posedge clk);
    @(negedge clk);
    predictor_resolved_control_flow_pc     = CALL_PC;
    predictor_resolved_control_flow_target = program_counter_t'('h8000_0400);
    predictor_resolved_control_flow_op     = CF_JAL;
    predictor_resolved_control_flow_rs1    = '0;
    predictor_resolved_control_flow_rd     = arch_reg_idx_t'(1);
    @(posedge clk);
    @(negedge clk);
    predictor_resolved_control_flow_occurred = 1'b0;
    query_predictor(RETURN_PC);
    assert (predictor_lookup_prediction.predicted_taken &&
            (predictor_lookup_next_pc == CALL_PC + program_counter_t'(INSTRUCTION_BYTES)))
    else $fatal(1, "return-address stack did not predict the call return target");

    // fence.i清除BTB和RAS可见状态，软件改写指令后不能继续采用旧控制流目标。
    predictor_invalidate = 1'b1;
    @(posedge clk);
    @(negedge clk);
    predictor_invalidate = 1'b0;
    query_predictor(JAL_PC);
    assert (!predictor_lookup_prediction.predicted_taken)
    else $fatal(1, "fence.i predictor invalidation left a visible BTB entry");

    clear_predictor_inputs();
  endtask

  task automatic check_decode_execute_stage;
    execute_packet_t first_packet;
    execute_packet_t second_packet;

    @(negedge clk);
    decoded_execute_packet =
        make_execute_packet(program_counter_t'('h100), arch_reg_idx_t'(5), xlen_data_t'('h1234));
    decoded_execute_packet_valid = 1'b1;
    execute_packet_ready = 1'b1;
    #1;
    assert (decoded_execute_packet_ready)
    else $fatal(1, "ID/EX stage did not accept an input while empty");

    @(posedge clk);
    #1;
    assert (execute_packet_valid && (execute_packet == decoded_execute_packet))
    else $fatal(1, "ID/EX stage did not publish the accepted payload");

    @(negedge clk);
    first_packet = execute_packet;
    execute_packet_ready = 1'b0;
    second_packet =
        make_execute_packet(program_counter_t'('h200), arch_reg_idx_t'(6), xlen_data_t'('h5678));
    decoded_execute_packet = second_packet;
    decoded_execute_packet_valid = 1'b1;
    #1;
    assert (decoded_execute_packet_ready)
    else $fatal(1, "ID/EX queue did not accept its second entry while the head was backpressured");

    @(posedge clk);
    #1;
    assert (execute_packet_valid && (execute_packet == first_packet))
    else $fatal(1, "ID/EX queue changed its head while accepting the second entry");

    @(negedge clk);
    decoded_execute_packet =
        make_execute_packet(program_counter_t'('h300), arch_reg_idx_t'(7), xlen_data_t'('h9abc));
    #1;
    assert (!decoded_execute_packet_ready)
    else $fatal(1, "ID/EX queue returned ready while both entries were occupied");

    @(posedge clk);
    #1;
    assert (execute_packet_valid && (execute_packet == first_packet))
    else $fatal(1, "ID/EX queue changed its head while full and backpressured");

    @(negedge clk);
    decoded_execute_packet_valid = 1'b0;
    execute_packet_ready         = 1'b1;

    @(posedge clk);
    #1;
    assert (execute_packet_valid && (execute_packet == second_packet))
    else $fatal(1, "ID/EX queue did not preserve FIFO order after releasing backpressure");

    @(negedge clk);
    decode_execute_flush = 1'b1;
    #1;
    assert (!decoded_execute_packet_ready)
    else $fatal(1, "ID/EX stage returned ready during flush");

    @(posedge clk);
    #1;
    assert (!execute_packet_valid)
    else $fatal(1, "ID/EX stage retained a flushed instruction");

    @(negedge clk);
    decode_execute_flush         = 1'b0;
    execute_packet_ready         = 1'b1;
    decoded_execute_packet_valid = 1'b0;
  endtask

  task automatic check_writeback_stage;
    writeback_result_t held_result;

    @(negedge clk);
    completion_result =
        make_writeback_result(program_counter_t'('h300), arch_reg_idx_t'(7), xlen_data_t'('h9abc));
    completion_result_valid = 1'b1;
    writeback_result_ready = 1'b1;
    #1;
    assert (completion_result_ready)
    else $fatal(1, "WB stage did not accept an input while empty");

    @(posedge clk);
    #1;
    assert (writeback_result_valid && (writeback_result == completion_result))
    else $fatal(1, "WB stage did not publish the accepted result");

    @(negedge clk);
    held_result = writeback_result;
    writeback_result_ready = 1'b0;
    completion_result =
        make_writeback_result(program_counter_t'('h400), arch_reg_idx_t'(8), xlen_data_t'('hdef0));
    completion_result_valid = 1'b1;
    #1;
    assert (!completion_result_ready)
    else $fatal(1, "WB stage accepted a replacement while backpressured");

    @(posedge clk);
    #1;
    assert (writeback_result_valid && (writeback_result == held_result))
    else $fatal(1, "WB stage changed its result while backpressured");

    @(negedge clk);
    writeback_flush = 1'b1;
    #1;
    assert (!completion_result_ready)
    else $fatal(1, "WB stage returned ready during commit recovery");

    @(posedge clk);
    #1;
    assert (!writeback_result_valid)
    else $fatal(1, "WB stage retained a younger result after commit recovery");

    @(negedge clk);
    writeback_flush         = 1'b0;
    writeback_result_ready  = 1'b1;
    completion_result_valid = 1'b0;
  endtask

  task automatic check_hazard_controller;
    @(negedge clk);
    clear_hazard_inputs();
    hazard_decoded_uop_valid = 1'b1;
    #1;
    assert (decode_accept_allowed && execute_issue_allowed)
    else $fatal(1, "hazard controller blocked a hazard-free instruction");

    hazard_decoded_uop.uses_rs1  = 1'b1;
    hazard_decoded_uop.rs1       = arch_reg_idx_t'(5);
    hazard_execute_uop_valid     = 1'b1;
    hazard_execute_uop.writes_rd = 1'b1;
    hazard_execute_uop.rd        = arch_reg_idx_t'(5);
    #1;
    assert (raw_hazard_present && !decode_accept_allowed)
    else $fatal(1, "execute-stage rs1 RAW hazard was not detected");

    execute_forwarding_available = 1'b1;
    #1;
    assert (!raw_hazard_present && decode_accept_allowed &&
            rs1_execute_forwarding_selected && !rs1_writeback_forwarding_selected)
    else $fatal(1, "available execute result was not selected for rs1 forwarding");

    // EX/MEM结果已经寄存，可以在ID/EX采样前写入payload。该生产者比LSU completion
    // 和WB年轻，因此同rd并存时必须优先选择EX/MEM值。
    clear_hazard_inputs();
    hazard_decoded_uop_valid              = 1'b1;
    hazard_decoded_uop.uses_rs1           = 1'b1;
    hazard_decoded_uop.rs1                = arch_reg_idx_t'(6);
    execute_result_valid                  = 1'b1;
    execute_result_writes_rd              = 1'b1;
    execute_result_rd                     = arch_reg_idx_t'(6);
    execute_result_forwarding_available   = 1'b1;
    hazard_writeback_result_valid         = 1'b1;
    hazard_writeback_result.uop.writes_rd = 1'b1;
    hazard_writeback_result.uop.rd        = arch_reg_idx_t'(6);
    writeback_forwarding_available        = 1'b1;
    #1;
    assert (!raw_hazard_present && decode_accept_allowed &&
            rs1_execute_result_forwarding_selected &&
            !rs1_writeback_forwarding_selected)
    else $fatal(1, "pipeline did not prioritize the EX/MEM value over WB");

    clear_hazard_inputs();
    hazard_decoded_uop_valid              = 1'b1;
    hazard_decoded_uop.uses_rs2           = 1'b1;
    hazard_decoded_uop.rs2                = arch_reg_idx_t'(9);
    hazard_writeback_result_valid         = 1'b1;
    hazard_writeback_result.uop.writes_rd = 1'b1;
    hazard_writeback_result.uop.rd        = arch_reg_idx_t'(9);
    #1;
    assert (raw_hazard_present && !decode_accept_allowed)
    else $fatal(1, "writeback-stage rs2 RAW hazard was not detected");

    writeback_forwarding_available = 1'b1;
    #1;
    assert (!raw_hazard_present && decode_accept_allowed &&
            rs2_writeback_forwarding_selected && !rs2_execute_forwarding_selected)
    else $fatal(1, "available writeback result was not selected for rs2 forwarding");

    // EX是更近的生产者。即使WB中存在同rd的旧值，只要EX结果尚不可用就必须停顿。
    clear_hazard_inputs();
    hazard_decoded_uop_valid              = 1'b1;
    hazard_decoded_uop.uses_rs1           = 1'b1;
    hazard_decoded_uop.rs1                = arch_reg_idx_t'(11);
    hazard_execute_uop_valid              = 1'b1;
    hazard_execute_uop.writes_rd          = 1'b1;
    hazard_execute_uop.rd                 = arch_reg_idx_t'(11);
    hazard_writeback_result_valid         = 1'b1;
    hazard_writeback_result.uop.writes_rd = 1'b1;
    hazard_writeback_result.uop.rd        = arch_reg_idx_t'(11);
    writeback_forwarding_available        = 1'b1;
    #1;
    assert (raw_hazard_present && !decode_accept_allowed &&
            !rs1_execute_forwarding_selected && !rs1_writeback_forwarding_selected)
    else $fatal(1, "pipeline forwarded a stale WB value past an unavailable EX producer");

    execute_forwarding_available = 1'b1;
    #1;
    assert (!raw_hazard_present && decode_accept_allowed &&
            rs1_execute_forwarding_selected && !rs1_writeback_forwarding_selected)
    else $fatal(1, "pipeline did not prioritize the newest EX producer");

    clear_hazard_inputs();
    hazard_decoded_uop_valid       = 1'b1;
    hazard_decoded_uop.serializing = 1'b1;
    hazard_execute_uop_valid       = 1'b1;
    #1;
    assert (serializing_hazard_present && !decode_accept_allowed)
    else $fatal(1, "serializing instruction entered before older work drained");

    clear_hazard_inputs();
    hazard_decoded_uop_valid       = 1'b1;
    hazard_execute_uop_valid       = 1'b1;
    hazard_execute_uop.serializing = 1'b1;
    #1;
    assert (serializing_hazard_present && !decode_accept_allowed)
    else $fatal(1, "younger instruction crossed an older serializing instruction");

    clear_hazard_inputs();
    hazard_decoded_uop_valid = 1'b1;
    lsu_busy                 = 1'b1;
    #1;
    assert (structural_hazard_present && decode_accept_allowed && !execute_issue_allowed)
    else $fatal(1, "pipeline issued a younger instruction ahead of an older LSU transaction");

    // 在途load是位于EX与WB之间的最新生产者。数据未返回时依赖指令停在ID；返回当拍
    // 可直接从LSU completion前递，不必额外等待写回寄存器堆。
    lsu_pending_writes_rd       = 1'b1;
    lsu_pending_rd              = arch_reg_idx_t'(13);
    hazard_decoded_uop.uses_rs1 = 1'b1;
    hazard_decoded_uop.rs1      = arch_reg_idx_t'(13);
    #1;
    assert (raw_hazard_present && !decode_accept_allowed && !rs1_lsu_forwarding_selected)
    else $fatal(1, "pending LSU load dependency was not blocked before response");

    lsu_forwarding_available = 1'b1;
    #1;
    assert (!raw_hazard_present && decode_accept_allowed && rs1_lsu_forwarding_selected)
    else $fatal(1, "LSU response was not selected for same-cycle forwarding");

    // EX中的生产者年龄比pending LSU更小。两者写同一rd时必须选择EX，不能前递老load值。
    hazard_execute_uop_valid     = 1'b1;
    hazard_execute_uop.writes_rd = 1'b1;
    hazard_execute_uop.rd        = arch_reg_idx_t'(13);
    execute_forwarding_available = 1'b1;
    #1;
    assert (rs1_execute_forwarding_selected && !rs1_lsu_forwarding_selected)
    else $fatal(1, "pipeline did not prioritize the younger EX producer over pending LSU");

    clear_hazard_inputs();
    clear_hazard_inputs();
    hazard_decoded_uop_valid  = 1'b1;
    frontend_redirect_applied = 1'b1;
    #1;
    // redirect经过寄存边界并应用到前端时，残留的旧路径EX内容必须停止执行。
    assert (!decode_accept_allowed && !execute_issue_allowed &&
            hazard_decode_execute_flush && !hazard_writeback_flush)
    else $fatal(1, "registered frontend redirect did not block stale execute work");

    clear_hazard_inputs();
    hazard_decoded_uop_valid = 1'b1;
    commit_redirect_occurred = 1'b1;
    #1;
    assert (!decode_accept_allowed && !execute_issue_allowed &&
            hazard_decode_execute_flush && hazard_writeback_flush)
    else $fatal(1, "commit redirect did not discard all younger work");

    clear_hazard_inputs();
  endtask

  task automatic check_fetch_buffer;
    fetch_entry_t first_entry;
    fetch_entry_t second_entry;
    fetch_entry_t third_entry;

    first_entry = make_fetch_entry(program_counter_t'('h8000_0000), instruction_t'(32'h0010_0093));
    second_entry = make_fetch_entry(program_counter_t'('h8000_0004), instruction_t'(32'h0020_0113));
    third_entry = make_fetch_entry(program_counter_t'('h8000_0008), instruction_t'(32'h0030_0193));

    // IDU停顿时连续接收两项。满队列的入口ready只依赖寄存占用量，不组合依赖本拍
    // 出队；这会切断EX冒险到IFU的跨级ready路径。首项出队后的下一拍即可补入第三项，
    // 队列中剩余的第二项保证IDU供给不中断。
    @(negedge clk);
    fetch_buffer_input_entry = first_entry;
    fetch_buffer_input_valid = 1'b1;
    #1;
    assert (fetch_buffer_input_ready && !fetch_buffer_output_valid)
    else $fatal(1, "empty fetch buffer did not accept its first entry");
    @(posedge clk);

    @(negedge clk);
    fetch_buffer_input_entry = second_entry;
    #1;
    assert (fetch_buffer_input_ready && fetch_buffer_output_valid &&
            (fetch_buffer_output_entry == first_entry))
    else $fatal(1, "fetch buffer did not retain the first entry while accepting the second");
    @(posedge clk);

    @(negedge clk);
    fetch_buffer_input_entry  = third_entry;
    fetch_buffer_output_ready = 1'b0;
    #1;
    assert (!fetch_buffer_input_ready && fetch_buffer_output_valid &&
            (fetch_buffer_output_entry == first_entry))
    else $fatal(1, "full fetch buffer accepted an entry without available capacity");

    fetch_buffer_output_ready = 1'b1;
    #1;
    assert (!fetch_buffer_input_ready)
    else $fatal(1, "full fetch buffer ready retained a downstream combinational dependency");
    @(posedge clk);

    @(negedge clk);
    #1;
    assert (fetch_buffer_input_ready && fetch_buffer_output_valid &&
            (fetch_buffer_output_entry == second_entry))
    else $fatal(1, "fetch buffer did not restore input capacity after dequeue");
    @(posedge clk);

    @(negedge clk);
    fetch_buffer_input_valid = 1'b0;
    #1;
    assert (fetch_buffer_output_valid && (fetch_buffer_output_entry == third_entry))
    else $fatal(1, "fetch buffer lost the replacement entry");

    fetch_buffer_output_ready = 1'b0;
    fetch_buffer_flush        = 1'b1;
    #1;
    assert (!fetch_buffer_input_ready)
    else $fatal(1, "fetch buffer accepted a new entry during redirect flush");
    @(posedge clk);

    @(negedge clk);
    fetch_buffer_flush = 1'b0;
    #1;
    assert (!fetch_buffer_output_valid)
    else $fatal(1, "fetch buffer exposed a wrong-path entry after flush");

    clear_fetch_buffer_inputs();
  endtask

  // 同一时刻可观察到三个不同年龄的异常：WB中的老load fault、ID/EX中的年轻非法指令，
  // 以及仍停在译码边界的更年轻取指fault。只有WB异常有权进入commit；提交级redirect
  // 必须拒绝同拍completion并清空所有年轻流水状态。
  task automatic check_precise_exception_age_priority;
    writeback_result_t older_lsu_exception;
    writeback_result_t younger_completion;
    execute_packet_t   younger_idu_exception;

    older_lsu_exception                       = '0;
    older_lsu_exception.uop.pc                = program_counter_t'(64'h8000_0040);
    older_lsu_exception.uop.instruction       = instruction_t'(32'h0000_2283);
    older_lsu_exception.uop.rd                = arch_reg_idx_t'(5);
    older_lsu_exception.uop.writes_rd         = 1'b1;
    older_lsu_exception.uop.mem_ctrl.cmd      = MEM_CMD_LOAD;
    older_lsu_exception.uop.exception_valid   = 1'b1;
    older_lsu_exception.uop.exception_cause   = EXC_LOAD_ACCESS_FAULT;
    older_lsu_exception.uop.exception_tval    = xlen_data_t'(64'h8000_4000);

    younger_idu_exception                     = '0;
    younger_idu_exception.uop.pc              = program_counter_t'(64'h8000_0044);
    younger_idu_exception.uop.instruction     = instruction_t'(32'hffff_ffff);
    younger_idu_exception.uop.exception_valid = 1'b1;
    younger_idu_exception.uop.exception_cause = EXC_ILLEGAL_INSTRUCTION;
    younger_idu_exception.uop.exception_tval  = xlen_data_t'(32'hffff_ffff);

    younger_completion                        = '0;
    younger_completion.uop.pc                 = program_counter_t'(64'h8000_0048);
    younger_completion.uop.exception_valid    = 1'b1;
    younger_completion.uop.exception_cause    = EXC_INSTR_ACCESS_FAULT;
    younger_completion.uop.exception_tval     = xlen_data_t'(64'h8000_0048);

    // 先让老异常进入WB，同时让下一条异常进入ID/EX。
    @(negedge clk);
    clear_hazard_inputs();
    writeback_flush              = 1'b0;
    decode_execute_flush         = 1'b0;
    completion_result            = older_lsu_exception;
    completion_result_valid      = 1'b1;
    decoded_execute_packet       = younger_idu_exception;
    decoded_execute_packet_valid = 1'b1;
    execute_packet_ready         = 1'b1;

    @(posedge clk);
    #1;
    assert (writeback_result_valid && execute_packet_valid)
    else $fatal(1, "exception age test did not populate WB and ID/EX");

    // WB异常提交的同一拍，再呈现一个更年轻completion和一个仍在decode的IFU异常。
    @(negedge clk);
    completion_result                  = younger_completion;
    completion_result_valid            = 1'b1;
    hazard_writeback_result            = writeback_result;
    hazard_writeback_result_valid      = writeback_result_valid;
    hazard_execute_uop                 = execute_packet.uop;
    hazard_execute_uop_valid           = execute_packet_valid;
    hazard_decoded_uop                 = '0;
    hazard_decoded_uop.exception_valid = 1'b1;
    hazard_decoded_uop.exception_cause = EXC_INSTR_ACCESS_FAULT;
    hazard_decoded_uop.exception_tval  = xlen_data_t'(64'h8000_004c);
    hazard_decoded_uop_valid           = 1'b1;
    #1;

    assert (staged_commit_valid && staged_commit.trap_taken && (staged_commit.trap_cause_code[$bits(
        exception_cause_e
    )-1:0] == EXC_LOAD_ACCESS_FAULT) && !staged_commit.gpr_write && !staged_commit.memory_access)
    else $fatal(1, "oldest LSU exception did not own the commit boundary");
    assert (staged_trap_redirect_valid &&
            (staged_trap_redirect.target_pc == program_counter_t'(64'h8000_0100)))
    else $fatal(1, "oldest exception did not produce the trap redirect");

    commit_redirect_occurred = staged_trap_redirect_valid;
    #1;
    assert (!decode_accept_allowed && !execute_issue_allowed &&
            hazard_decode_execute_flush && hazard_writeback_flush)
    else $fatal(1, "commit exception did not block and flush younger instructions");

    decode_execute_flush = hazard_decode_execute_flush;
    writeback_flush      = hazard_writeback_flush;
    #1;
    assert (!completion_result_ready && !decoded_execute_packet_ready)
    else $fatal(1, "young exception payload was accepted during precise recovery");

    @(posedge clk);
    #1;
    assert (!writeback_result_valid && !execute_packet_valid)
    else $fatal(1, "younger exception survived the oldest exception redirect");

    @(negedge clk);
    completion_result_valid      = 1'b0;
    decoded_execute_packet_valid = 1'b0;
    decode_execute_flush         = 1'b0;
    writeback_flush              = 1'b0;
    clear_hazard_inputs();
  endtask

  task automatic check_ifu_zero_bubble_lookup;
    icache_lookup_req_t active_request;
    icache_lookup_req_t next_request;
    icache_lookup_req_t stalled_request;
    fetch_entry_t       stalled_fetch_entry;
    redirect_req_t      redirect_request;

    // 接收复位后的第一条请求。此前ready保持为0，因此IFU仍应稳定呈现复位PC。
    @(negedge clk);
    icache_lookup_req_ready = 1'b1;
    ifu_fetch_entry_ready   = 1'b1;
    #1;
    assert (icache_lookup_req_valid &&
            (icache_lookup_req.fetch_addr == phys_addr_t'(IFU_TEST_START_PC)))
    else $fatal(1, "IFU did not present the reset-vector lookup");
    active_request = icache_lookup_req;

    @(posedge clk);

    // 模拟同步I-cache连续命中。每个响应出现时，IFU都必须同拍呈现下一条PC请求；
    // request ready保持为1，因此旧响应和新请求在每个循环周期同时握手。
    for (int unsigned instruction_index = 0; instruction_index < 6; instruction_index++) begin
      @(negedge clk);
      icache_lookup_resp =
          make_lookup_response(active_request, instruction_t'(32'h0000_0013 + instruction_index));
      icache_lookup_resp_valid = 1'b1;
      #1;
      assert (ifu_fetch_entry_valid && icache_lookup_resp_ready)
      else $fatal(1, "IFU did not deliver a current I-cache response");
      assert (ifu_fetch_entry.pc == program_counter_t'(active_request.fetch_addr))
      else $fatal(1, "IFU delivered a response with the wrong PC");
      assert (icache_lookup_req_valid &&
              (icache_lookup_req.fetch_addr ==
               active_request.fetch_addr + phys_addr_t'(INSTRUCTION_BYTES)))
      else $fatal(1, "IFU inserted a request bubble after an I-cache hit");

      next_request = icache_lookup_req;
      @(posedge clk);
      active_request = next_request;
    end

    // IDU反压时，当前响应必须由I-cache通道保持，且IFU不能越过尚未交付的响应。
    @(negedge clk);
    icache_lookup_resp = make_lookup_response(active_request, instruction_t'(32'h0000_0093));
    ifu_fetch_entry_ready = 1'b0;
    #1;
    stalled_fetch_entry = ifu_fetch_entry;
    assert (ifu_fetch_entry_valid && !icache_lookup_resp_ready && !icache_lookup_req_valid)
    else $fatal(1, "IFU advanced while its response was backpressured");

    @(posedge clk);
    @(negedge clk);
    #1;
    assert (ifu_fetch_entry_valid && (ifu_fetch_entry == stalled_fetch_entry) &&
            !icache_lookup_resp_ready && !icache_lookup_req_valid)
    else $fatal(1, "IFU response changed while downstream was stalled");

    ifu_fetch_entry_ready = 1'b1;
    #1;
    assert (icache_lookup_resp_ready && icache_lookup_req_valid)
    else $fatal(1, "IFU did not resume zero-bubble lookup after downstream stall");
    next_request = icache_lookup_req;
    @(posedge clk);
    active_request = next_request;

    // critical word可以先交付，但阻塞式miss可能仍占用I-cache。下一请求虽然当拍呈现，
    // ready=0时必须在响应离开后继续由SEND状态稳定保持，不能丢失或改变payload。
    @(negedge clk);
    icache_lookup_resp       = make_lookup_response(active_request, instruction_t'(32'h0000_0113));
    icache_lookup_req_ready  = 1'b0;
    icache_lookup_resp_valid = 1'b1;
    #1;
    assert (ifu_fetch_entry_valid && icache_lookup_resp_ready && icache_lookup_req_valid)
    else $fatal(1, "IFU did not present the next request with an early response");
    stalled_request = icache_lookup_req;

    @(posedge clk);
    @(negedge clk);
    icache_lookup_resp_valid = 1'b0;
    #1;
    assert (icache_lookup_req_valid && (icache_lookup_req == stalled_request))
    else $fatal(1, "IFU lost a next request rejected during early response delivery");

    icache_lookup_req_ready = 1'b1;
    @(posedge clk);
    active_request = stalled_request;

    // redirect发生在旧请求等待响应期间：更新epoch和目标PC，但仍排空已经发出的旧响应。
    @(negedge clk);
    redirect_request           = '0;
    redirect_request.target_pc = program_counter_t'('h8000_1000);
    redirect_request.source_pc = program_counter_t'(active_request.fetch_addr);
    redirect_request.reason    = REDIRECT_BRANCH_MISPREDICT;
    ifu_redirect_req           = redirect_request;
    ifu_redirect_req_valid     = 1'b1;
    #1;
    assert (!icache_lookup_req_valid)
    else $fatal(1, "IFU presented a sequential request during redirect");

    @(posedge clk);
    @(negedge clk);
    ifu_redirect_req_valid   = 1'b0;
    icache_lookup_resp       = make_lookup_response(active_request, instruction_t'(32'h0000_0193));
    icache_lookup_resp_valid = 1'b1;
    #1;
    assert (!ifu_fetch_entry_valid && icache_lookup_resp_ready && !icache_lookup_req_valid)
    else $fatal(1, "IFU did not discard the old-epoch response after redirect");

    @(posedge clk);
    @(negedge clk);
    icache_lookup_resp_valid = 1'b0;
    #1;
    assert (icache_lookup_req_valid &&
            (icache_lookup_req.fetch_addr == phys_addr_t'(redirect_request.target_pc)) &&
            (icache_lookup_req.fetch_epoch != active_request.fetch_epoch))
    else $fatal(1, "IFU did not restart from the redirect target with a new epoch");

    clear_ifu_inputs();
  endtask

  initial begin
    clk                          = 1'b0;
    rst_ni                       = 1'b0;
    decoded_execute_packet       = '0;
    decoded_execute_packet_valid = 1'b0;
    execute_packet_ready         = 1'b1;
    decode_execute_flush         = 1'b0;
    completion_result            = '0;
    completion_result_valid      = 1'b0;
    writeback_result_ready       = 1'b1;
    writeback_flush              = 1'b0;
    clear_ifu_inputs();
    clear_hazard_inputs();
    clear_fetch_buffer_inputs();
    clear_predictor_inputs();

    repeat (2) @(posedge clk);
    rst_ni = 1'b1;

    check_decode_execute_stage();
    check_writeback_stage();
    check_hazard_controller();
    check_fetch_buffer();
    check_fetch_control_flow_predictor();
    check_precise_exception_age_priority();
    check_ifu_zero_bubble_lookup();

    $display("pipeline control tests passed: XLEN=%0d", XLEN);
    $finish;
  end

endmodule
