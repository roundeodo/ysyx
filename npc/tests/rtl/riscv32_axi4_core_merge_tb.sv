module riscv32_axi4_core_merge_tb;
  import riscv32_axi4_pkg::*;

  localparam axi4_addr_t INSTRUCTION_READ_ADDR = axi4_addr_t'(32'h8000_0100);
  localparam axi4_addr_t DATA_READ_ADDR        = axi4_addr_t'(32'h8000_0200);

  logic clk;
  logic rst_ni;

  axi4_manager_to_target_t instruction_manager;
  axi4_target_to_manager_t instruction_response;
  axi4_manager_to_target_t data_manager;
  axi4_target_to_manager_t data_response;
  axi4_manager_to_target_t downstream_manager;
  axi4_target_to_manager_t downstream_response;

  riscv32_axi4_core_merge u_dut (
      .clk_i                (clk),
      .rst_ni               (rst_ni),
      .instruction_manager_i(instruction_manager),
      .instruction_manager_o(instruction_response),
      .data_manager_i       (data_manager),
      .data_manager_o       (data_response),
      .downstream_manager_o (downstream_manager),
      .downstream_manager_i (downstream_response)
  );

  always #5 clk = ~clk;

  initial begin
    clk                  = 1'b0;
    rst_ni               = 1'b0;
    instruction_manager  = '0;
    data_manager         = '0;
    downstream_response  = '0;

    instruction_manager.r_ready = 1'b1;
    data_manager.r_ready        = 1'b1;

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_ni = 1'b1;

    // 两个cache同时请求共享读口。复位后的首个轮询优先级给指令侧；target暂时
    // 反压AR，用于验证仲裁结果和地址在握手前不会改变。
    instruction_manager.ar.addr  = INSTRUCTION_READ_ADDR;
    instruction_manager.ar.id    = axi4_id_t'(1);
    instruction_manager.ar.len   = 8'd1;
    instruction_manager.ar.size  = 3'($clog2(AXI4_STRB_WIDTH));
    instruction_manager.ar.burst = AXI4_BURST_INCR;
    instruction_manager.ar_valid = 1'b1;

    data_manager.ar.addr          = DATA_READ_ADDR;
    data_manager.ar.id            = axi4_id_t'(2);
    data_manager.ar.len           = 8'd0;
    data_manager.ar.size          = 3'($clog2(AXI4_STRB_WIDTH));
    data_manager.ar.burst         = AXI4_BURST_INCR;
    data_manager.ar_valid         = 1'b1;

    downstream_response.ar_ready  = 1'b0;
    #1;
    assert (downstream_manager.ar_valid &&
            downstream_manager.ar.addr == INSTRUCTION_READ_ADDR)
      else $fatal(1, "simultaneous I/D request did not select instruction requester first");

    @(posedge clk);
    @(negedge clk);
    #1;
    assert (downstream_manager.ar_valid &&
            downstream_manager.ar.addr == INSTRUCTION_READ_ADDR)
      else $fatal(1, "blocked instruction AR request was not held stable");

    downstream_response.ar_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    instruction_manager.ar_valid = 1'b0;
    downstream_response.ar_ready = 1'b0;

    // 指令burst返回期间，等待中的数据AR不能替换响应接收者。
    downstream_response.r_valid = 1'b1;
    downstream_response.r.data  = axi4_data_t'(64'h1111_1111_1111_1111);
    downstream_response.r.id    = axi4_id_t'(1);
    downstream_response.r.resp  = AXI4_RESP_OKAY;
    downstream_response.r.last  = 1'b0;
    #1;
    assert (instruction_response.r_valid && !data_response.r_valid)
      else $fatal(1, "first instruction burst beat was routed to the wrong requester");
    @(posedge clk);

    @(negedge clk);
    downstream_response.r.data = axi4_data_t'(64'h2222_2222_2222_2222);
    downstream_response.r.last = 1'b1;
    #1;
    assert (instruction_response.r_valid && !data_response.r_valid)
      else $fatal(1, "instruction RLAST was routed to the wrong requester");
    @(posedge clk);

    // 指令事务完成后，轮询优先级转给一直等待的数据侧。
    @(negedge clk);
    downstream_response.r_valid = 1'b0;
    #1;
    assert (downstream_manager.ar_valid &&
            downstream_manager.ar.addr == DATA_READ_ADDR)
      else $fatal(1, "waiting data request was not selected after instruction RLAST");

    @(posedge clk);
    @(negedge clk);
    downstream_response.ar_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    data_manager.ar_valid         = 1'b0;
    downstream_response.ar_ready = 1'b0;
    downstream_response.r_valid  = 1'b1;
    downstream_response.r.data   = axi4_data_t'(64'h3333_3333_3333_3333);
    downstream_response.r.id     = axi4_id_t'(2);
    downstream_response.r.resp   = AXI4_RESP_OKAY;
    downstream_response.r.last   = 1'b1;
    #1;
    assert (data_response.r_valid && !instruction_response.r_valid)
      else $fatal(1, "data read response was routed to the wrong requester");
    @(posedge clk);

    @(negedge clk);
    downstream_response.r_valid = 1'b0;
    $display("AXI4 I/D shared-read arbitration directed test passed");
    $finish;
  end

endmodule
