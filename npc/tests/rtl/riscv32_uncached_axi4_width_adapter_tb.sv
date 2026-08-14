module riscv32_uncached_axi4_width_adapter_tb;

  import riscv_config_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;

  logic clk_i;
  logic rst_ni;

  data_memory_req_t  data_memory_req_i;
  logic              data_memory_req_valid_i;
  logic              data_memory_req_ready_o;
  data_memory_resp_t data_memory_resp_o;
  logic              data_memory_resp_valid_o;
  logic              data_memory_resp_ready_i;

  axi4_manager_to_target_t axi_manager_o;
  axi4_target_to_manager_t axi_manager_i;

  riscv32_uncached_axi4_master dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic fail(input string message);
    $error("width adapter test failed: %s", message);
    $fatal(1);
  endtask

  task automatic apply_reset;
    clk_i                    = 1'b0;
    rst_ni                   = 1'b0;
    data_memory_req_i        = '0;
    data_memory_req_valid_i  = 1'b0;
    data_memory_resp_ready_i = 1'b0;
    axi_manager_i            = '0;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;
  endtask

  task automatic send_core_request(input data_memory_req_t request);
    @(negedge clk_i);
    data_memory_req_i       = request;
    data_memory_req_valid_i = 1'b1;
    do @(posedge clk_i); while (!data_memory_req_ready_o);
    @(negedge clk_i);
    data_memory_req_valid_i = 1'b0;
    data_memory_req_i       = '0;
  endtask

  task automatic accept_read_address(
      input axi4_addr_t expected_addr,
      input logic [7:0] expected_len,
      input logic [2:0] expected_size
  );
    do @(negedge clk_i); while (!axi_manager_o.ar_valid);
    if (axi_manager_o.ar.addr != expected_addr) fail("unexpected ARADDR");
    if (axi_manager_o.ar.len != expected_len) fail("unexpected ARLEN");
    if (axi_manager_o.ar.size != expected_size) fail("unexpected ARSIZE");
    if (axi_manager_o.ar.burst != AXI4_BURST_INCR) fail("AR must use INCR burst");

    // 阻塞一个周期，确认valid及其payload在ready到来前保持稳定。
    axi_manager_i.ar_ready = 1'b0;
    @(negedge clk_i);
    if (!axi_manager_o.ar_valid || axi_manager_o.ar.addr != expected_addr)
      fail("AR payload changed under backpressure");
    axi_manager_i.ar_ready = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    axi_manager_i.ar_ready = 1'b0;
  endtask

  task automatic send_read_beat(
      input axi4_data_t data,
      input axi4_resp_e resp,
      input logic last
  );
    @(negedge clk_i);
    axi_manager_i.r.data  = data;
    axi_manager_i.r.id    = AXI_ID_WIDTH'(1);
    axi_manager_i.r.resp  = resp;
    axi_manager_i.r.last  = last;
    axi_manager_i.r_valid = 1'b1;
    do @(posedge clk_i); while (!axi_manager_o.r_ready);
    @(negedge clk_i);
    axi_manager_i.r_valid = 1'b0;
    axi_manager_i.r       = '0;
  endtask

  task automatic check_core_response(
      input core_data_t expected_data,
      input logic expected_access_fault,
      input mem_txn_id_t expected_transaction_id
  );
    do @(negedge clk_i); while (!data_memory_resp_valid_o);
    if (data_memory_resp_o.read_data != expected_data) fail("unexpected core read data");
    if (data_memory_resp_o.access_fault != expected_access_fault)
      fail("unexpected core access-fault status");
    if (data_memory_resp_o.transaction_id != expected_transaction_id)
      fail("unexpected core transaction ID");

    // 本地消费者阻塞时，完整响应必须保持稳定。
    data_memory_resp_ready_i = 1'b0;
    @(negedge clk_i);
    if (!data_memory_resp_valid_o || data_memory_resp_o.read_data != expected_data)
      fail("core response changed under backpressure");
    data_memory_resp_ready_i = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    data_memory_resp_ready_i = 1'b0;
  endtask

  task automatic accept_write_address(
      input axi4_addr_t expected_addr,
      input logic [7:0] expected_len,
      input logic [2:0] expected_size
  );
    do @(negedge clk_i); while (!axi_manager_o.aw_valid);
    if (axi_manager_o.aw.addr != expected_addr) fail("unexpected AWADDR");
    if (axi_manager_o.aw.len != expected_len) fail("unexpected AWLEN");
    if (axi_manager_o.aw.size != expected_size) fail("unexpected AWSIZE");

    axi_manager_i.aw_ready = 1'b0;
    @(negedge clk_i);
    if (!axi_manager_o.aw_valid || axi_manager_o.aw.addr != expected_addr)
      fail("AW payload changed under backpressure");
    axi_manager_i.aw_ready = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    axi_manager_i.aw_ready = 1'b0;
  endtask

  task automatic accept_write_beat(
      input axi4_data_t expected_data,
      input axi4_strb_t expected_strobe,
      input logic expected_last
  );
    do @(negedge clk_i); while (!axi_manager_o.w_valid);
    if (axi_manager_o.w.data != expected_data) fail("unexpected WDATA");
    if (axi_manager_o.w.strb != expected_strobe) fail("unexpected WSTRB");
    if (axi_manager_o.w.last != expected_last) fail("unexpected WLAST");

    axi_manager_i.w_ready = 1'b0;
    @(negedge clk_i);
    if (!axi_manager_o.w_valid || axi_manager_o.w.data != expected_data ||
        axi_manager_o.w.strb != expected_strobe || axi_manager_o.w.last != expected_last)
      fail("W payload changed under backpressure");
    axi_manager_i.w_ready = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    axi_manager_i.w_ready = 1'b0;
  endtask

  task automatic send_write_response(input axi4_resp_e resp);
    @(negedge clk_i);
    axi_manager_i.b.id      = AXI_ID_WIDTH'(2);
    axi_manager_i.b.resp    = resp;
    axi_manager_i.b_valid   = 1'b1;
    do @(posedge clk_i); while (!axi_manager_o.b_ready);
    @(negedge clk_i);
    axi_manager_i.b_valid = 1'b0;
    axi_manager_i.b       = '0;
  endtask

  task automatic run_aligned_doubleword_read;
    data_memory_req_t request;
    request                = '0;
    request.addr           = 32'h0000_0100;
    request.cmd            = MEM_CMD_LOAD;
    request.size           = MEM_SIZE_DOUBLE;
    request.transaction_id = mem_txn_id_t'(3);
    send_core_request(request);
    accept_read_address(32'h0000_0100, 8'd1, 3'd2);
    send_read_beat(32'h4433_2211, AXI4_RESP_OKAY, 1'b0);
    send_read_beat(32'h8877_6655, AXI4_RESP_OKAY, 1'b1);
    check_core_response(64'h8877_6655_4433_2211, 1'b0, mem_txn_id_t'(3));
  endtask

  task automatic run_second_read_beat_error;
    data_memory_req_t request;
    request                = '0;
    request.addr           = 32'h0000_0180;
    request.cmd            = MEM_CMD_LOAD;
    request.size           = MEM_SIZE_DOUBLE;
    request.transaction_id = mem_txn_id_t'(4);
    send_core_request(request);
    accept_read_address(32'h0000_0180, 8'd1, 3'd2);
    send_read_beat(32'h0302_0100, AXI4_RESP_OKAY, 1'b0);
    send_read_beat(32'h0706_0504, AXI4_RESP_SLVERR, 1'b1);
    check_core_response(64'h0706_0504_0302_0100, 1'b1, mem_txn_id_t'(4));
  endtask

  task automatic run_aligned_doubleword_write;
    data_memory_req_t request;
    request                = '0;
    request.addr           = 32'h0000_0200;
    request.cmd            = MEM_CMD_STORE;
    request.size           = MEM_SIZE_DOUBLE;
    request.write_data     = 64'h8877_6655_4433_2211;
    request.byte_strobe    = 8'hff;
    request.transaction_id = mem_txn_id_t'(5);
    send_core_request(request);
    fork
      accept_write_address(32'h0000_0200, 8'd1, 3'd2);
      begin
        accept_write_beat(32'h4433_2211, 4'b1111, 1'b0);
        accept_write_beat(32'h8877_6655, 4'b1111, 1'b1);
      end
    join
    send_write_response(AXI4_RESP_OKAY);
    check_core_response('0, 1'b0, mem_txn_id_t'(5));
  endtask

  task automatic run_narrow_write(
      input phys_addr_t addr,
      input mem_size_e size,
      input core_data_t core_write_data,
      input core_byte_strobe_t core_strobe,
      input axi4_data_t expected_axi_data,
      input axi4_strb_t expected_axi_strobe
  );
    data_memory_req_t request;
    request                = '0;
    request.addr           = addr;
    request.cmd            = MEM_CMD_STORE;
    request.size           = size;
    request.write_data     = core_write_data;
    request.byte_strobe    = core_strobe;
    request.transaction_id = mem_txn_id_t'(6);
    send_core_request(request);
    fork
      accept_write_address(axi4_addr_t'(addr), 8'd0, 3'(size));
      accept_write_beat(expected_axi_data, expected_axi_strobe, 1'b1);
    join
    send_write_response(AXI4_RESP_OKAY);
    check_core_response('0, 1'b0, mem_txn_id_t'(6));
  endtask

  initial begin
    apply_reset();

    if (CORE_DATA_WIDTH != 64 || AXI_DATA_WIDTH != 32)
      fail("test must use a 64-bit core beat and a 32-bit AXI beat");

    run_aligned_doubleword_read();
    run_second_read_beat_error();
    run_aligned_doubleword_write();

    run_narrow_write(32'h0000_0305, MEM_SIZE_BYTE,
                     64'h0000_aa00_0000_0000, 8'b0010_0000,
                     32'h0000_aa00, 4'b0010);
    run_narrow_write(32'h0000_0306, MEM_SIZE_HALF,
                     64'hbeef_0000_0000_0000, 8'b1100_0000,
                     32'hbeef_0000, 4'b1100);
    run_narrow_write(32'h0000_0304, MEM_SIZE_WORD,
                     64'hcafe_babe_0000_0000, 8'b1111_0000,
                     32'hcafe_babe, 4'b1111);

    $display("P2 width-adapter tests passed");
    $finish;
  end

endmodule
