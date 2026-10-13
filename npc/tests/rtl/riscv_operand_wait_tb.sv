module riscv_operand_wait_tb;
  import riscv_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  logic flush = 0;
  execute_packet_t request, result;
  logic request_valid = 0;
  logic request_ready, result_valid, operands_ready;
  logic result_ready = 0;
  logic [1:0] pending;
  scoreboard_index_t source_index[2];
  completion_source_e source_port[2];
  arithmetic_result_t completion[3];
  logic [2:0] completion_valid;
  xlen_data_t muldiv_operand_array[2];
  int checks = 0;
  riscv_id_ex_reg dut (
      .muldiv_operand_array_o(muldiv_operand_array),
      .clk_i(clk),
      .rst_ni(rst_n),
      .flush_i(flush),
      .decoded_execute_packet_i(request),
      .decoded_execute_packet_valid_i(request_valid),
      .decoded_execute_packet_ready_o(request_ready),
      .execute_packet_o(result),
      .execute_packet_valid_o(result_valid),
      .execute_packet_ready_i(result_ready),
      .operand_pending_vector_i(pending),
      .operand_producer_index_array_i(source_index),
      .operand_completion_source_array_i(source_port),
      .completion_result_array_i(completion),
      .completion_valid_vector_i(completion_valid),
      .operands_ready_o(operands_ready),
      .execute_forwardable_producer_present_o(),
      .execute_blocking_producer_present_o(),
      .execute_serializing_instruction_present_o()
  );
  task automatic tick;
    #2;
    clk = 1;
    #2;
    clk = 0;
    #2;
  endtask
  task automatic check(input logic condition, input string message);
    checks++;
    assert (condition)
    else $fatal(1, "%s", message);
  endtask
  initial begin
    request          = '0;
    pending          = '0;
    completion_valid = '0;
    source_index     = '{scoreboard_index_t'(1), scoreboard_index_t'(2)};
    completion       = '{default: '0};
    source_port      = '{default: COMPLETION_LSU};
    tick();
    rst_n = 1;
    tick();
    for (int iteration = 0; iteration < 64; iteration++) begin
      request.uop.pc               = 64'h80000000 + 64'(iteration * 4);
      request.source_a_value       = '1;
      request.source_b_value       = '1;
      source_port[iteration%2]     = completion_source_e'(iteration % 3);
      source_port[(iteration+1)%2] = completion_source_e'((iteration + 1) % 3);
      pending                      = 2'b11;
      request_valid                = 1;
      tick();
      request_valid = 0;
      check(result_valid && !operands_ready && !request_ready, "Missing operand did not hold EX");
      // An unrelated result must not wake either source.
      completion[0]    = {scoreboard_index_t'(3), 64'd99};
      completion_valid = 3'b001;
      #1;
      check(!operands_ready && result_valid, "Unrelated producer woke operand");
      tick();
      completion_valid = '0;
      // Alternate arrival order and all completion ports.
      for (int arrival = 0; arrival < 2; arrival++) begin
        automatic int source = (iteration + arrival) % 2;
        automatic int port_number = (iteration + arrival) % 3;
        completion[port_number]       = {source_index[source], 64'(iteration * 2 + source)};
        completion_valid[port_number] = 1'b1;
        #1;
        check(operands_ready == (arrival == 1), "Ready before both operands arrived");
        if (source == 0)
          check(result.source_a_value == 64'(iteration * 2), "Missing same-cycle A forwarding");
        else
          check(result.source_b_value == 64'(iteration * 2 + 1), "Missing same-cycle B forwarding");
        tick();
        completion_valid = '0;
      end
      #1;
      check(
          operands_ready && result.source_a_value == 64'(iteration * 2) &&
          result.source_b_value == 64'(iteration * 2 + 1),
          "Returned operands were not retained");
      tick();
      result_ready = 1;
      tick();
      result_ready = 0;
      check(!result_valid, "Instruction did not leave EX");
    end
    // A completed old transaction on another FU may retain the same reused index.
    source_port[0] = COMPLETION_LSU;
    pending        = 2'b01;
    request_valid  = 1;
    tick();
    request_valid                   = 0;
    completion[COMPLETION_MULTIPLY] = {source_index[0], 64'd99};
    completion_valid                = 3'b010;
    #1;
    check(!operands_ready, "Wrong completion port woke a reused index");
    tick();
    completion[COMPLETION_LSU] = {source_index[0], 64'd77};
    completion_valid           = 3'b011;
    #1;
    check(operands_ready && result.source_a_value == 64'd77,
          "Selected completion data included another FU's stale value");
    tick();
    completion_valid = '0;
    #1;
    check(operands_ready && result.source_a_value == 64'd77, "Selected operand was not retained");
    result_ready = 1;
    tick();
    result_ready = 0;
    check(!result_valid, "Selected-port instruction did not leave EX");
    // A load feeding MUL/DIV is captured before execution; arithmetic return bypass stays direct.
    request.uop.fu_type = FU_MULDIV;
    for (int port_number = 0; port_number < 3; port_number++) begin
      source_port[0] = completion_source_e'(port_number);
      pending        = 2'b01;
      request_valid  = 1;
      tick();
      request_valid           = 0;
      completion[port_number] = {source_index[0], 64'd123};
      completion_valid        = 3'b001 << port_number;
      #1;
      check(operands_ready == (port_number != COMPLETION_LSU), "Arithmetic input capture policy");
      check(muldiv_operand_array[0] == (port_number == COMPLETION_LSU ? '1 : 64'd123),
            "Load bypass leaked into arithmetic input");
      tick();
      completion_valid = '0;
      #1;
      check(operands_ready && muldiv_operand_array[0] == 64'd123, "Arithmetic operand capture");
      result_ready = 1;
      tick();
      result_ready = 0;
    end
    pending       = 2'b11;
    request_valid = 1;
    tick();
    request_valid = 0;
    flush         = 1;
    tick();
    flush            = 0;
    completion_valid = 3'b111;
    #1;
    check(!result_valid && operands_ready, "Flush retained waiting instruction");
    $display("PASS operand wait: %0d checks", checks);
    $finish;
  end
endmodule
