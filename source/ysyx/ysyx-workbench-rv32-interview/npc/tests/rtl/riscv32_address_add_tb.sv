// 独立算术参考验证真实 EXU 的 AGU 输出，不直接调用被测函数。
module riscv32_address_add_tb;
  import riscv32_pkg::*;
  execute_packet_t packet;
  execute_result_t result;
  lsu_req_t lsu_request;
  redirect_req_t redirect;
  logic packet_ready, result_valid, lsu_valid, redirect_valid;
  int checks = 0;

  riscv32_exu dut (
      .execute_packet_i(packet), .execute_packet_valid_i(1'b1),
      .execute_packet_issue_allowed_i(1'b1), .execute_packet_ready_o(packet_ready),
      .exu_result_o(result), .exu_result_valid_o(result_valid), .exu_result_ready_i(1'b1),
      .lsu_req_o(lsu_request), .lsu_req_valid_o(lsu_valid), .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(redirect), .sequential_redirect_valid_o(redirect_valid)
  );

  task automatic check_sum(input xlen_data_t base, offset);
    xlen_data_t expected;
    packet.source_a_value = base;
    packet.uop.imm = offset;
    expected = base + offset;
    #1;
    if (!lsu_valid || !packet_ready || result_valid ||
        lsu_request.effective_addr != effective_addr_t'(expected))
      $fatal(1, "AGU %h + %h = %h expected %h", base, offset,
             lsu_request.effective_addr, expected);
    checks++;
  endtask

  initial begin
    packet = '0;
    packet.uop.fu_type = FU_LSU;
    // 每一位生成/传播长进位，检查跨组进位、借位效果与最高位回绕。
    for (int bit_index = 0; bit_index < XLEN; bit_index++) begin
      check_sum((xlen_data_t'(1) << bit_index) - 1'b1, 1);
      check_sum(~(xlen_data_t'(1) << bit_index), xlen_data_t'(1) << bit_index);
      check_sum(xlen_data_t'(1) << bit_index, '1);
      check_sum('1, xlen_data_t'(1) << bit_index);
    end
    for (int index = 0; index < 100000; index++) begin
      check_sum(xlen_data_t'({$urandom, $urandom}),
                xlen_data_t'({$urandom, $urandom}));
    end
    $display("PASS AGU: XLEN=%0d, %0d independent arithmetic checks", XLEN, checks);
    $finish;
  end
endmodule
