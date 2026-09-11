module riscv32_uncached_axi4_master_tb;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  import riscv32_addr_map_pkg::*;

  logic clk;
  logic rst_ni;

  data_memory_req_t data_memory_req;
  logic             data_memory_req_valid;
  logic             data_memory_req_ready;
  data_memory_resp_t data_memory_resp;
  logic              data_memory_resp_valid;
  logic              data_memory_resp_ready;

  axi4_manager_to_target_t axi_manager;
  axi4_target_to_manager_t axi_target;

  localparam mem_size_e MAX_ACCESS_SIZE =
      (CORE_DATA_WIDTH == 64) ? MEM_SIZE_DOUBLE : MEM_SIZE_WORD;
  localparam axi4_data_t TEST_DATA = axi4_data_t'(64'h8877_6655_4433_2211);

  riscv32_uncached_axi4_master u_uncached_axi4_master (
      .clk_i                    (clk),
      .rst_ni                   (rst_ni),
      .data_memory_req_i        (data_memory_req),
      .data_memory_req_valid_i  (data_memory_req_valid),
      .data_memory_req_ready_o  (data_memory_req_ready),
      .data_memory_resp_o       (data_memory_resp),
      .data_memory_resp_valid_o (data_memory_resp_valid),
      .data_memory_resp_ready_i (data_memory_resp_ready),
      .axi_manager_o            (axi_manager),
      .axi_manager_i            (axi_target)
  );

  always #5 clk = ~clk;

  task automatic send_local_request(input data_memory_req_t request);
    @(negedge clk);
    data_memory_req       = request;
    data_memory_req_valid = 1'b1;
    #1;
    assert (data_memory_req_ready)
      else $fatal(1, "uncached adapter did not accept local request");
    @(posedge clk);
    #1;
    data_memory_req_valid = 1'b0;
  endtask

  task automatic consume_local_response(
      input core_data_t expected_data,
      input logic       expected_access_fault
  );
    assert (data_memory_resp_valid)
      else $fatal(1, "uncached adapter did not produce local response");
    assert ((data_memory_resp.read_data == expected_data) &&
            (data_memory_resp.access_fault == expected_access_fault) &&
            (data_memory_resp.transaction_id == 4'h9))
      else $fatal(1, "uncached local response mismatch");

    @(posedge clk);
    #1;
    assert (data_memory_resp_valid &&
            (data_memory_resp.read_data == expected_data) &&
            (data_memory_resp.access_fault == expected_access_fault))
      else $fatal(1, "uncached local response changed under backpressure");

    @(negedge clk);
    data_memory_resp_ready = 1'b1;
    @(posedge clk);
    #1;
    data_memory_resp_ready = 1'b0;
    assert (!data_memory_resp_valid)
      else $fatal(1, "uncached local response was not consumed");
  endtask

  task automatic check_read_path;
    data_memory_req_t request;
    axi4_read_address_t held_read_address;

    request                = '0;
    request.addr           = phys_addr_t'(32'h8000_0040);
    request.cmd            = MEM_CMD_LOAD;
    request.size           = MAX_ACCESS_SIZE;
    request.transaction_id = 4'h9;
    send_local_request(request);

    assert (axi_manager.ar_valid &&
            (axi_manager.ar.addr == request.addr) &&
            (axi_manager.ar.len == 0) &&
            (axi_manager.ar.size == 3'(MAX_ACCESS_SIZE)))
      else $fatal(1, "uncached AXI read address payload mismatch");
    held_read_address = axi_manager.ar;

    repeat (2) begin
      @(posedge clk);
      #1;
      assert (axi_manager.ar_valid && (axi_manager.ar == held_read_address))
        else $fatal(1, "uncached AR payload changed under backpressure");
    end

    @(negedge clk);
    axi_target.ar_ready = 1'b1;
    @(posedge clk);
    #1;
    axi_target.ar_ready = 1'b0;

    @(negedge clk);
    axi_target.r       = '0;
    axi_target.r.id    = axi4_id_t'(1);
    axi_target.r.data  = TEST_DATA;
    axi_target.r.resp  = AXI4_RESP_OKAY;
    axi_target.r.last  = 1'b1;
    axi_target.r_valid = 1'b1;
    #1;
    consume_local_response(core_data_t'(TEST_DATA), 1'b0);
    axi_target.r_valid = 1'b0;
  endtask

  task automatic check_write_path;
    data_memory_req_t request;
    axi4_write_address_t held_write_address;

    request                = '0;
    request.addr           = phys_addr_t'(32'h8000_0080);
    request.cmd            = MEM_CMD_STORE;
    request.size           = MAX_ACCESS_SIZE;
    request.write_data     = core_data_t'(TEST_DATA);
    request.byte_strobe    = '1;
    request.transaction_id = 4'h9;
    send_local_request(request);

    assert (axi_manager.aw_valid && axi_manager.w_valid &&
            (axi_manager.aw.len == 0) &&
            (axi_manager.aw.size == 3'(MAX_ACCESS_SIZE)) &&
            (axi_manager.w.data == TEST_DATA) &&
            (axi_manager.w.strb == '1) && axi_manager.w.last)
      else $fatal(1, "uncached AXI write payload mismatch");
    held_write_address = axi_manager.aw;

    // W先完成，AW继续受反压，证明两个channel没有被错误绑定为同拍握手。
    @(negedge clk);
    axi_target.w_ready = 1'b1;
    @(posedge clk);
    #1;
    axi_target.w_ready = 1'b0;
    assert (axi_manager.aw_valid && !axi_manager.w_valid &&
            (axi_manager.aw == held_write_address))
      else $fatal(1, "uncached adapter did not preserve pending AW after W handshake");

    @(negedge clk);
    axi_target.aw_ready = 1'b1;
    @(posedge clk);
    #1;
    axi_target.aw_ready = 1'b0;

    @(negedge clk);
    axi_target.b       = '0;
    axi_target.b.id    = axi4_id_t'(2);
    axi_target.b.resp  = AXI4_RESP_SLVERR;
    axi_target.b_valid = 1'b1;
    #1;
    consume_local_response('0, 1'b1);
    axi_target.b_valid = 1'b0;
  endtask

  initial begin
    clk                    = 1'b0;
    rst_ni                 = 1'b0;
    data_memory_req        = '0;
    data_memory_req_valid  = 1'b0;
    data_memory_resp_ready = 1'b0;
    axi_target             = '0;

    repeat (3) @(posedge clk);
    rst_ni = 1'b1;

    check_read_path();
    check_write_path();

    $display("Uncached AXI4 directed test passed for data width=%0d", MEM_AXI_DATA_WIDTH);
    $finish;
  end

endmodule
