module riscv32_muldiv_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
  logic flush = 0;
  logic valid = 0, ready = 0, issue = 1;
  fetch_entry_t fetch;
  decoded_uop_t decoded;
  execute_packet_t packet;
  execute_result_t result;
  logic result_valid, packet_ready, lsu_valid, redirect_valid, muldiv_available;
  lsu_req_t lsu_req;
  redirect_req_t redirect;

  riscv32_idu u_idu (
      .fetch_entry_i(fetch), .fetch_entry_valid_i(1'b1), .fetch_entry_ready_o(),
      .decoded_uop_o(decoded), .decoded_uop_valid_o(), .decoded_uop_ready_i(1'b1)
  );
  riscv32_exu u_exu (
      .muldiv_result_available_o(muldiv_available),
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .execute_packet_i(packet),
      .multiply_operand_a_i(packet.source_a_value[31:0]),
      .multiply_operand_b_i(packet.source_b_value[31:0]), .execute_packet_valid_i(valid),
      .execute_packet_issue_allowed_i(issue), .execute_packet_ready_o(packet_ready),
      .exu_result_o(result), .exu_result_valid_o(result_valid), .exu_result_ready_i(ready),
      .lsu_req_o(lsu_req), .lsu_req_valid_o(lsu_valid), .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(redirect), .sequential_redirect_valid_o(redirect_valid)
  );

  task automatic cycle;
    @(posedge clk); #1; @(negedge clk); #1;
  endtask

  string vectors;
  integer fd, scanned, operation, expected_cycles, abort_cycle;
  integer count = 0, cancellations = 0, cycles;
  logic [31:0] a, b, expected;
  initial begin
    fetch = '0; packet = '0;
    cycle(); rst_n = 1; cycle();
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "missing vectors");
    fd = $fopen(vectors, "r");
    if (!fd) $fatal(1, "cannot open vectors");
    while (!$feof(fd)) begin
      scanned = $fscanf(fd, "%d %h %h %h %d %d\n", operation, a, b, expected,
                        expected_cycles, abort_cycle);
      if (scanned != 6) $fatal(1, "bad vector");
      fetch = '0;
      fetch.pc = 32'h80000100;
      fetch.instruction = {7'b0000001, 5'd2, 5'd1, 3'(operation), 5'd3, 7'b0110011};
      #1;
      if (!MULDIV_ENABLE) begin
        assert (decoded.exception_valid && !decoded.writes_rd &&
                decoded.exception_cause == EXC_ILLEGAL_INSTRUCTION)
          else $fatal(1, "disabled M accepted instruction");
        count++;
        continue;
      end
      assert (!decoded.exception_valid && decoded.fu_type == FU_MULDIV &&
              decoded.muldiv_op == muldiv_op_e'(operation) && decoded.uses_rs1 &&
              decoded.uses_rs2 && decoded.writes_rd)
        else $fatal(1, "M decode mismatch");
      packet = '0; packet.uop = decoded;
      packet.source_a_value = a; packet.source_b_value = b;
      // 故意附带错误 taken，要求多周期运算未完成时绝不先恢复。
      packet.uop.prediction.predicted_taken = 1'b1;
      packet.uop.prediction.predicted_target = 32'h80002000;
      valid = 1; ready = 0; issue = 1; cycles = 1; #1;
      while (!result_valid && cycles < 40 && cycles != abort_cycle) begin
        assert (!packet_ready && !redirect_valid && !lsu_valid)
          else $fatal(1, "early M completion/redirect");
        // 暂停发出时，算法状态及结果均不得交付。
        if ((count % 11) == 0) begin
          issue = 0; cycle();
          assert (!result_valid && !redirect_valid) else $fatal(1, "blocked issue completed");
          issue = 1; #1;
        end
        cycle(); cycles++;
      end
      if (cycles == abort_cycle) begin
        flush = 1; issue = 0; cycle(); flush = 0; valid = 0; issue = 1;
        cycle();
        assert (!result_valid && !redirect_valid) else $fatal(1, "cancelled M leaked");
        cancellations++;
      end else begin
        assert (result_valid && result.result == expected && cycles == expected_cycles)
          else $fatal(1, "op=%d a=%h b=%h got=%h expected=%h cycles=%d expected=%d",
                      operation, a, b, result.result, expected, cycles, expected_cycles);
        // 恢复/发出门控不得进入算术就绪网络，但必须阻止结果交付和重定向。
        issue = 0; ready = 1; cycle();
        assert (muldiv_available && result.result == expected && !result_valid && !redirect_valid)
          else $fatal(1, "issue hold changed arithmetic availability or leaked completion");
        issue = 1; ready = 0; #1;
        // 末拍随机长度反压，结果和预测身份必须保持。
        repeat (count % 5) begin
          cycle();
          assert (result_valid && result.result == expected && !redirect_valid && !packet_ready)
            else $fatal(1, "stalled final result changed");
        end
        ready = 1; #1;
        assert (packet_ready && redirect_valid && redirect.target_pc == 32'h80000104)
          else $fatal(1, "final result/redirect handshake missing");
        cycle(); valid = 0; ready = 0;
        #1;
        assert (!result_valid && !redirect_valid) else $fatal(1, "duplicate completion");
      end
      count++;
    end
    $display("PASS M enabled=%0d vectors=%0d cancellations=%0d", MULDIV_ENABLE, count, cancellations);
    $finish;
  end
endmodule
