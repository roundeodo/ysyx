module riscv32_pipeline_control_tb;
  import riscv32_pkg::*;

  logic              clk;
  logic              rst_ni;

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
      .writeback_result_valid_i    (hazard_writeback_result_valid),
      .writeback_writes_rd_i       (hazard_writeback_result.uop.writes_rd),
      .writeback_rd_i              (hazard_writeback_result.uop.rd),
      .writeback_serializing_i     (hazard_writeback_result.uop.serializing),
      .lsu_busy_i                  (lsu_busy),
      .execute_redirect_occurred_i (execute_redirect_occurred),
      .commit_redirect_occurred_i  (commit_redirect_occurred),
      .decode_accept_allowed_o     (decode_accept_allowed),
      .execute_issue_allowed_o     (execute_issue_allowed),
      .decode_execute_flush_o      (hazard_decode_execute_flush),
      .writeback_flush_o           (hazard_writeback_flush),
      .raw_hazard_present_o        (raw_hazard_present),
      .serializing_hazard_present_o(serializing_hazard_present),
      .structural_hazard_present_o (structural_hazard_present)
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
    clear_hazard_inputs();

    repeat (2) @(posedge clk);
    rst_ni = 1'b1;

    check_decode_execute_stage();
    check_writeback_stage();
    check_hazard_controller();

    $display("pipeline control tests passed: XLEN=%0d", XLEN);
    $finish;
  end

endmodule
