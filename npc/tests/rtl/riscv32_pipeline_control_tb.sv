module riscv32_pipeline_control_tb;
  import riscv32_addr_map_pkg::*;
  import riscv32_pkg::*;

  localparam program_counter_t IFU_TEST_START_PC = program_counter_t'('h8000_0000);

  logic clk;
  logic rst_ni;

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

  fetch_entry_t fetch_buffer_input_entry;
  logic         fetch_buffer_input_valid;
  logic         fetch_buffer_input_ready;
  fetch_entry_t fetch_buffer_output_entry;
  logic         fetch_buffer_output_valid;
  logic         fetch_buffer_output_ready;
  logic         fetch_buffer_flush;

  fetch_entry_t   predictor_fetch_entry;
  logic           predictor_fetch_entry_handshake_occurred;
  program_counter_t predictor_resolved_branch_pc;
  logic             predictor_resolved_branch_occurred;
  logic             predictor_resolved_branch_taken;
  fetch_entry_t     predictor_output_entry;
  redirect_req_t   predictor_redirect_req;
  logic            predictor_redirect_req_valid;

  execute_packet_t   decoded_execute_packet;
  logic              decoded_execute_packet_valid;
  logic              decoded_execute_packet_ready;
  execute_packet_t   execute_packet;
  logic              execute_packet_valid;
  logic              execute_packet_ready;
  logic              decode_execute_flush;

  writeback_result_t completion_result;
  logic              completion_result_valid;
  logic              completion_result_ready;
  writeback_result_t writeback_result;
  logic              writeback_result_valid;
  logic              writeback_result_ready;
  logic              writeback_flush;

  commit_t           staged_commit;
  logic              staged_commit_valid;
  redirect_req_t     staged_trap_redirect;
  logic              staged_trap_redirect_valid;

  decoded_uop_t      hazard_decoded_uop;
  logic              hazard_decoded_uop_valid;
  decoded_uop_t      hazard_execute_uop;
  logic              hazard_execute_uop_valid;
  writeback_result_t hazard_writeback_result;
  logic              hazard_writeback_result_valid;
  logic              lsu_busy;
  logic              execute_redirect_occurred;
  logic              commit_redirect_occurred;
  logic              decode_accept_allowed;
  logic              execute_issue_allowed;
  logic              hazard_decode_execute_flush;
  logic              hazard_writeback_flush;
  logic              raw_hazard_present;
  logic              serializing_hazard_present;
  logic              structural_hazard_present;
  logic              execute_forwarding_available;
  logic              writeback_forwarding_available;
  logic              rs1_execute_forwarding_selected;
  logic              rs1_writeback_forwarding_selected;
  logic              rs2_execute_forwarding_selected;
  logic              rs2_writeback_forwarding_selected;

  riscv32_ifu #(
      .PC_START(IFU_TEST_START_PC)
  ) u_ifu (
      .clk_i                     (clk),
      .rst_ni                    (rst_ni),
      .redirect_req_i            (ifu_redirect_req),
      .redirect_req_valid_i      (ifu_redirect_req_valid),
      .icache_lookup_req_o       (icache_lookup_req),
      .icache_lookup_req_valid_o (icache_lookup_req_valid),
      .icache_lookup_req_ready_i (icache_lookup_req_ready),
      .icache_lookup_resp_i      (icache_lookup_resp),
      .icache_lookup_resp_valid_i(icache_lookup_resp_valid),
      .icache_lookup_resp_ready_o(icache_lookup_resp_ready),
      .fetch_entry_o             (ifu_fetch_entry),
      .fetch_entry_valid_o       (ifu_fetch_entry_valid),
      .fetch_entry_ready_i       (ifu_fetch_entry_ready)
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
      .clk_i                                (clk),
      .rst_ni                               (rst_ni),
      .fetch_entry_i                        (predictor_fetch_entry),
      .fetch_entry_handshake_occurred_i     (predictor_fetch_entry_handshake_occurred),
      .resolved_conditional_branch_pc_i     (predictor_resolved_branch_pc),
      .resolved_conditional_branch_occurred_i(predictor_resolved_branch_occurred),
      .resolved_conditional_branch_taken_i  (predictor_resolved_branch_taken),
      .predicted_fetch_entry_o              (predictor_output_entry),
      .prediction_redirect_req_o            (predictor_redirect_req),
      .prediction_redirect_req_valid_o      (predictor_redirect_req_valid)
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
      .clk_i                       (clk),
      .rst_ni                      (rst_ni),
      .decoded_uop_valid_i         (hazard_decoded_uop_valid),
      .decoded_uses_rs1_i          (hazard_decoded_uop.uses_rs1),
      .decoded_rs1_i               (hazard_decoded_uop.rs1),
      .decoded_uses_rs2_i          (hazard_decoded_uop.uses_rs2),
      .decoded_rs2_i               (hazard_decoded_uop.rs2),
      .decoded_serializing_i       (hazard_decoded_uop.serializing),
      .execute_uop_valid_i         (hazard_execute_uop_valid),
      .execute_writes_rd_i         (hazard_execute_uop.writes_rd),
      .execute_rd_i                (hazard_execute_uop.rd),
      .execute_serializing_i       (hazard_execute_uop.serializing),
      .execute_forwarding_available_i(execute_forwarding_available),
      .writeback_result_valid_i    (hazard_writeback_result_valid),
      .writeback_writes_rd_i       (hazard_writeback_result.uop.writes_rd),
      .writeback_rd_i              (hazard_writeback_result.uop.rd),
      .writeback_serializing_i     (hazard_writeback_result.uop.serializing),
      .writeback_forwarding_available_i(writeback_forwarding_available),
      .lsu_busy_i                  (lsu_busy),
      .execute_redirect_occurred_i (execute_redirect_occurred),
      .commit_redirect_occurred_i  (commit_redirect_occurred),
      .decode_accept_allowed_o     (decode_accept_allowed),
      .execute_issue_allowed_o     (execute_issue_allowed),
      .decode_execute_flush_o      (hazard_decode_execute_flush),
      .writeback_flush_o           (hazard_writeback_flush),
      .raw_hazard_present_o        (raw_hazard_present),
      .serializing_hazard_present_o(serializing_hazard_present),
      .structural_hazard_present_o (structural_hazard_present),
      .rs1_execute_forwarding_selected_o(rs1_execute_forwarding_selected),
      .rs1_writeback_forwarding_selected_o(rs1_writeback_forwarding_selected),
      .rs2_execute_forwarding_selected_o(rs2_execute_forwarding_selected),
      .rs2_writeback_forwarding_selected_o(rs2_writeback_forwarding_selected)
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

  function automatic icache_lookup_resp_t make_lookup_response(
      input icache_lookup_req_t request, input instruction_t instruction);
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
  endtask

  task automatic clear_hazard_inputs;
    hazard_decoded_uop            = '0;
    hazard_decoded_uop_valid      = 1'b0;
    hazard_execute_uop            = '0;
    hazard_execute_uop_valid      = 1'b0;
    hazard_writeback_result       = '0;
    hazard_writeback_result_valid = 1'b0;
    lsu_busy                      = 1'b0;
    execute_redirect_occurred     = 1'b0;
    commit_redirect_occurred      = 1'b0;
    execute_forwarding_available  = 1'b0;
    writeback_forwarding_available = 1'b0;
  endtask

  function automatic fetch_entry_t make_fetch_entry(input program_counter_t pc,
                                                      input instruction_t instruction);
    fetch_entry_t entry;
    entry             = '0;
    entry.pc          = pc;
    entry.instruction = instruction;
    return entry;
  endfunction

  function automatic instruction_t make_branch_instruction(input logic signed [12:0] immediate);
    instruction_t instruction;
    instruction = '0;
    instruction[31]    = immediate[12];
    instruction[30:25] = immediate[10:5];
    instruction[14:12] = 3'b000;
    instruction[11:8]  = immediate[4:1];
    instruction[7]     = immediate[11];
    instruction[6:0]   = OPCODE_BRANCH;
    return instruction;
  endfunction

  function automatic instruction_t make_jal_instruction(input logic signed [20:0] immediate);
    instruction_t instruction;
    instruction = '0;
    instruction[31]    = immediate[20];
    instruction[30:21] = immediate[10:1];
    instruction[20]    = immediate[11];
    instruction[19:12] = immediate[19:12];
    instruction[6:0]   = OPCODE_JAL;
    return instruction;
  endfunction

  task automatic clear_fetch_buffer_inputs;
    fetch_buffer_input_entry  = '0;
    fetch_buffer_input_valid  = 1'b0;
    fetch_buffer_output_ready = 1'b0;
    fetch_buffer_flush        = 1'b0;
  endtask

  task automatic clear_predictor_inputs;
    predictor_fetch_entry                      = '0;
    predictor_fetch_entry_handshake_occurred   = 1'b0;
    predictor_resolved_branch_pc               = '0;
    predictor_resolved_branch_occurred          = 1'b0;
    predictor_resolved_branch_taken             = 1'b0;
  endtask

  task automatic check_fetch_control_flow_predictor;
    localparam program_counter_t JAL_PC    = program_counter_t'('h8000_0100);
    localparam program_counter_t BRANCH_PC = program_counter_t'('h8000_0200);
    instruction_t branch_instruction;

    branch_instruction = make_branch_instruction(13'sd8);

    // JAL目标由当前指令立即数直接形成，不需要BTB。只有该fetch entry实际进入
    // fetch buffer时才允许redirect，反压期间不能重复改变IFU的取指PC。
    @(negedge clk);
    predictor_fetch_entry = make_fetch_entry(JAL_PC, make_jal_instruction(21'sd8));
    #1;
    assert (predictor_output_entry.prediction.predicted_taken &&
            (predictor_output_entry.prediction.predicted_target == JAL_PC + 8) &&
            !predictor_redirect_req_valid)
      else $fatal(1, "fetch predictor did not predecode JAL without firing under backpressure");

    predictor_fetch_entry_handshake_occurred = 1'b1;
    #1;
    assert (predictor_redirect_req_valid &&
            (predictor_redirect_req.target_pc == JAL_PC + 8) &&
            (predictor_redirect_req.reason == REDIRECT_FETCH_PREDICTION))
      else $fatal(1, "fetch predictor did not redirect an accepted JAL");

    // BHT复位为弱不跳转；尚未解析过的条件分支必须先走顺序路径。
    predictor_fetch_entry = make_fetch_entry(BRANCH_PC, branch_instruction);
    #1;
    assert (!predictor_output_entry.prediction.predicted_taken &&
            !predictor_redirect_req_valid &&
            (predictor_output_entry.prediction.predicted_target ==
             BRANCH_PC + program_counter_t'(INSTRUCTION_BYTES)))
      else $fatal(1, "fresh BHT entry did not start at weak-not-taken");

    // 同一PC的真实taken结果在EX级训练方向表。两次训练把计数器从01推进到11。
    predictor_fetch_entry_handshake_occurred = 1'b0;
    predictor_resolved_branch_pc              = BRANCH_PC;
    predictor_resolved_branch_occurred         = 1'b1;
    predictor_resolved_branch_taken            = 1'b1;
    repeat (2) @(posedge clk);

    @(negedge clk);
    predictor_resolved_branch_occurred        = 1'b0;
    predictor_fetch_entry_handshake_occurred = 1'b1;
    #1;
    assert (predictor_output_entry.prediction.predicted_taken &&
            predictor_redirect_req_valid &&
            (predictor_redirect_req.target_pc == BRANCH_PC + 8))
      else $fatal(1, "trained BHT entry did not predict the conditional branch taken");

    // 两次not-taken训练把11退回01，预测应恢复顺序执行。
    predictor_fetch_entry_handshake_occurred = 1'b0;
    predictor_resolved_branch_occurred        = 1'b1;
    predictor_resolved_branch_taken           = 1'b0;
    repeat (2) @(posedge clk);

    @(negedge clk);
    predictor_resolved_branch_occurred = 1'b0;
    #1;
    assert (!predictor_output_entry.prediction.predicted_taken)
      else $fatal(1, "BHT saturating counter did not learn repeated not-taken outcomes");

    // 保留funct3、已有取指异常和非4字节对齐目标都不能触发前端预测。
    predictor_fetch_entry.instruction        = branch_instruction;
    predictor_fetch_entry.instruction[14:12] = 3'b010;
    #1;
    assert (!predictor_output_entry.prediction.predicted_taken)
      else $fatal(1, "reserved branch encoding produced a prediction");

    predictor_fetch_entry = make_fetch_entry(BRANCH_PC, make_jal_instruction(21'sd8));
    predictor_fetch_entry.exception_valid = 1'b1;
    #1;
    assert (!predictor_output_entry.prediction.predicted_taken)
      else $fatal(1, "exceptional fetch entry produced a prediction");

    predictor_fetch_entry = make_fetch_entry(BRANCH_PC, make_jal_instruction(21'sd2));
    #1;
    assert (!predictor_output_entry.prediction.predicted_taken)
      else $fatal(1, "misaligned direct-jump target produced a prediction");

    predictor_fetch_entry = make_fetch_entry(BRANCH_PC, instruction_t'(32'h0000_0067));
    #1;
    assert (!predictor_output_entry.prediction.predicted_taken)
      else $fatal(1, "JALR was predicted without a BTB or RAS target source");

    clear_predictor_inputs();
  endtask

  task automatic check_decode_execute_stage;
    execute_packet_t held_packet;

    @(negedge clk);
    decoded_execute_packet       = 
                                   make_execute_packet(program_counter_t'('h100), arch_reg_idx_t'(5), xlen_data_t'('h1234));
    decoded_execute_packet_valid = 1'b1;
    execute_packet_ready         = 1'b1;
    #1;
    assert (decoded_execute_packet_ready)
    else $fatal(1, "ID/EX stage did not accept an input while empty");

    @(posedge clk);
    #1;
    assert (execute_packet_valid && (execute_packet == decoded_execute_packet))
    else $fatal(1, "ID/EX stage did not publish the accepted payload");

    @(negedge clk);
    held_packet                  = execute_packet;
    execute_packet_ready         = 1'b0;
    decoded_execute_packet       = 
                                   make_execute_packet(program_counter_t'('h200), arch_reg_idx_t'(6), xlen_data_t'('h5678));
    decoded_execute_packet_valid = 1'b1;
    #1;
    assert (!decoded_execute_packet_ready)
    else $fatal(1, "ID/EX stage accepted a replacement while backpressured");

    @(posedge clk);
    #1;
    assert (execute_packet_valid && (execute_packet == held_packet))
    else $fatal(1, "ID/EX stage changed its payload while backpressured");

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
    completion_result       = 
                              make_writeback_result(program_counter_t'('h300), arch_reg_idx_t'(7), xlen_data_t'('h9abc));
    completion_result_valid = 1'b1;
    writeback_result_ready  = 1'b1;
    #1;
    assert (completion_result_ready)
    else $fatal(1, "WB stage did not accept an input while empty");

    @(posedge clk);
    #1;
    assert (writeback_result_valid && (writeback_result == completion_result))
    else $fatal(1, "WB stage did not publish the accepted result");

    @(negedge clk);
    held_result             = writeback_result;
    writeback_result_ready  = 1'b0;
    completion_result       = 
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
    assert (structural_hazard_present && !decode_accept_allowed && !execute_issue_allowed)
    else $fatal(1, "blocking LSU structural hazard was not enforced");

    clear_hazard_inputs();
    hazard_decoded_uop_valid  = 1'b1;
    execute_redirect_occurred = 1'b1;
    #1;
    assert (!decode_accept_allowed && execute_issue_allowed &&
            hazard_decode_execute_flush && !hazard_writeback_flush)
    else $fatal(1, "execute redirect did not preserve the redirecting instruction");

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

    first_entry  = make_fetch_entry(program_counter_t'('h8000_0000), instruction_t'(32'h0010_0093));
    second_entry = make_fetch_entry(program_counter_t'('h8000_0004), instruction_t'(32'h0020_0113));
    third_entry  = make_fetch_entry(program_counter_t'('h8000_0008), instruction_t'(32'h0030_0193));

    // IDU停顿时连续接收两项，第三项只有在同拍出队腾出空间时才能被接收。
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
    assert (fetch_buffer_input_ready)
    else $fatal(1, "full fetch buffer did not allow simultaneous dequeue and enqueue");
    @(posedge clk);

    @(negedge clk);
    fetch_buffer_input_valid = 1'b0;
    #1;
    assert (fetch_buffer_output_valid && (fetch_buffer_output_entry == second_entry))
    else $fatal(1, "fetch buffer changed instruction order after simultaneous transfer");
    @(posedge clk);

    @(negedge clk);
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

    older_lsu_exception                            = '0;
    older_lsu_exception.uop.pc                     = program_counter_t'(64'h8000_0040);
    older_lsu_exception.uop.instruction            = instruction_t'(32'h0000_2283);
    older_lsu_exception.uop.rd                     = arch_reg_idx_t'(5);
    older_lsu_exception.uop.writes_rd              = 1'b1;
    older_lsu_exception.uop.mem_ctrl.cmd            = MEM_CMD_LOAD;
    older_lsu_exception.uop.exception_valid         = 1'b1;
    older_lsu_exception.uop.exception_cause         = EXC_LOAD_ACCESS_FAULT;
    older_lsu_exception.uop.exception_tval          = xlen_data_t'(64'h8000_4000);

    younger_idu_exception                          = '0;
    younger_idu_exception.uop.pc                   = program_counter_t'(64'h8000_0044);
    younger_idu_exception.uop.instruction          = instruction_t'(32'hffff_ffff);
    younger_idu_exception.uop.exception_valid       = 1'b1;
    younger_idu_exception.uop.exception_cause       = EXC_ILLEGAL_INSTRUCTION;
    younger_idu_exception.uop.exception_tval        = xlen_data_t'(32'hffff_ffff);

    younger_completion                             = '0;
    younger_completion.uop.pc                      = program_counter_t'(64'h8000_0048);
    younger_completion.uop.exception_valid         = 1'b1;
    younger_completion.uop.exception_cause         = EXC_INSTR_ACCESS_FAULT;
    younger_completion.uop.exception_tval          = xlen_data_t'(64'h8000_0048);

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
    completion_result                         = younger_completion;
    completion_result_valid                   = 1'b1;
    hazard_writeback_result                   = writeback_result;
    hazard_writeback_result_valid             = writeback_result_valid;
    hazard_execute_uop                        = execute_packet.uop;
    hazard_execute_uop_valid                  = execute_packet_valid;
    hazard_decoded_uop                        = '0;
    hazard_decoded_uop.exception_valid        = 1'b1;
    hazard_decoded_uop.exception_cause        = EXC_INSTR_ACCESS_FAULT;
    hazard_decoded_uop.exception_tval         = xlen_data_t'(64'h8000_004c);
    hazard_decoded_uop_valid                  = 1'b1;
    #1;

    assert (staged_commit_valid && staged_commit.trap_taken &&
            (staged_commit.trap_cause_code[$bits(exception_cause_e)-1:0] ==
             EXC_LOAD_ACCESS_FAULT) &&
            !staged_commit.gpr_write && !staged_commit.memory_access)
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
    writeback_flush       = hazard_writeback_flush;
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
      icache_lookup_resp = make_lookup_response(
          active_request, instruction_t'(32'h0000_0013 + instruction_index)
      );
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
    redirect_request                 = '0;
    redirect_request.target_pc       = program_counter_t'('h8000_1000);
    redirect_request.source_pc       = program_counter_t'(active_request.fetch_addr);
    redirect_request.reason          = REDIRECT_BRANCH_MISPREDICT;
    ifu_redirect_req                 = redirect_request;
    ifu_redirect_req_valid           = 1'b1;
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
