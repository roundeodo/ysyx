module sdram_axi_transaction_classification_tb;
  localparam logic [3:0] SDRAM_CMD_READ            = 4'b0101;
  localparam logic [3:0] SDRAM_CMD_BURST_TERMINATE = 4'b0110;

  logic        clock;
  logic        reset;
  logic        in_awready;
  logic        in_awvalid;
  logic [31:0] in_awaddr;
  logic [ 3:0] in_awid;
  logic [ 7:0] in_awlen;
  logic [ 2:0] in_awsize;
  logic [ 1:0] in_awburst;
  logic        in_wready;
  logic        in_wvalid;
  logic [31:0] in_wdata;
  logic [ 3:0] in_wstrb;
  logic        in_wlast;
  logic        in_bready;
  logic        in_bvalid;
  logic [ 1:0] in_bresp;
  logic [ 3:0] in_bid;
  logic        in_arready;
  logic        in_arvalid;
  logic [31:0] in_araddr;
  logic [ 3:0] in_arid;
  logic [ 7:0] in_arlen;
  logic [ 2:0] in_arsize;
  logic [ 1:0] in_arburst;
  logic        in_rready;
  logic        in_rvalid;
  logic [ 1:0] in_rresp;
  logic [31:0] in_rdata;
  logic        in_rlast;
  logic [ 3:0] in_rid;
  logic        sdram_clk;
  logic        sdram_cke;
  logic        sdram_cs;
  logic        sdram_ras;
  logic        sdram_cas;
  logic        sdram_we;
  logic [12:0] sdram_a;
  logic [ 1:0] sdram_ba;
  logic [ 3:0] sdram_dqm;
  wire  [31:0] sdram_dq;

  integer sdram_read_command_count;
  integer sdram_burst_terminate_command_count;

  sdram_top_axi u_sdram_controller (
      .*
  );

  sdram u_sdram_model (
      .clk (sdram_clk),
      .cke (sdram_cke),
      .cs  (sdram_cs),
      .ras (sdram_ras),
      .cas (sdram_cas),
      .we  (sdram_we),
      .a   (sdram_a),
      .ba  (sdram_ba),
      .dqm (sdram_dqm),
      .dq  (sdram_dq)
  );

  always #1 clock = ~clock;

  // SDRAM在sdram_clk上升沿接收命令。统计物理命令可以直接验证AXI事务分类，
  // 不依赖I-cache、D-cache或其他manager的模块身份。
  always @(posedge sdram_clk) begin
    if (sdram_cke) begin
      case ({sdram_cs, sdram_ras, sdram_cas, sdram_we})
        SDRAM_CMD_READ:            sdram_read_command_count <= sdram_read_command_count + 1;
        SDRAM_CMD_BURST_TERMINATE: sdram_burst_terminate_command_count <=
                                       sdram_burst_terminate_command_count + 1;
        default: ;
      endcase
    end
  end

  task automatic issue_read_transaction(
      input logic [31:0] address,
      input logic [ 7:0] burst_length,
      input logic [ 2:0] transfer_size,
      input logic [ 1:0] burst_type,
      input logic [ 3:0] transaction_id
  );
    integer wait_cycle_count;
    begin
      @(negedge clock);
      in_araddr  = address;
      in_arlen   = burst_length;
      in_arsize  = transfer_size;
      in_arburst = burst_type;
      in_arid    = transaction_id;
      in_arvalid = 1'b1;

      wait_cycle_count = 0;
      while (!in_arready) begin
        @(negedge clock);
        wait_cycle_count = wait_cycle_count + 1;
        if (wait_cycle_count > 20000)
          $fatal(1, "AXI AR handshake timeout");
      end

      @(posedge clock);
      @(negedge clock);
      in_arvalid = 1'b0;
    end
  endtask

  task automatic receive_read_response(
      input integer      beat_count,
      input logic [31:0] first_expected_data,
      input logic [ 3:0] expected_transaction_id,
      input integer      backpressure_cycle_count
  );
    integer beat_index;
    integer wait_cycle_count;
    begin
      repeat (backpressure_cycle_count) @(posedge clock);
      @(negedge clock);
      in_rready = 1'b1;

      for (beat_index = 0; beat_index < beat_count; beat_index = beat_index + 1) begin
        wait_cycle_count = 0;
        while (!in_rvalid) begin
          @(negedge clock);
          wait_cycle_count = wait_cycle_count + 1;
          if (wait_cycle_count > 20000)
            $fatal(1, "AXI R response timeout at beat %0d", beat_index);
        end

        assert (in_rdata == first_expected_data + beat_index)
          else $fatal(1, "beat %0d data mismatch: expected=%08x actual=%08x",
                      beat_index, first_expected_data + beat_index, in_rdata);
        assert (in_rid == expected_transaction_id)
          else $fatal(1, "beat %0d ID mismatch: expected=%x actual=%x",
                      beat_index, expected_transaction_id, in_rid);
        assert (in_rresp == 2'b00)
          else $fatal(1, "beat %0d response error: %b", beat_index, in_rresp);
        assert (in_rlast == (beat_index == beat_count - 1))
          else $fatal(1, "beat %0d RLAST mismatch", beat_index);

        @(posedge clock);
        @(negedge clock);
      end

      in_rready = 1'b0;
    end
  endtask

  integer memory_word_index;
  integer read_command_count_before_transaction;
  integer terminate_command_count_before_transaction;

  initial begin
    clock      = 1'b0;
    reset      = 1'b1;
    in_awvalid = 1'b0;
    in_awaddr  = 32'd0;
    in_awid    = 4'd0;
    in_awlen   = 8'd0;
    in_awsize  = 3'd2;
    in_awburst = 2'd1;
    in_wvalid  = 1'b0;
    in_wdata   = 32'd0;
    in_wstrb   = 4'd0;
    in_wlast   = 1'b0;
    in_bready  = 1'b1;
    in_arvalid = 1'b0;
    in_araddr  = 32'd0;
    in_arid    = 4'd0;
    in_arlen   = 8'd0;
    in_arsize  = 3'd2;
    in_arburst = 2'd1;
    in_rready  = 1'b0;
    sdram_read_command_count            = 0;
    sdram_burst_terminate_command_count = 0;

    for (memory_word_index = 0; memory_word_index < 256; memory_word_index = memory_word_index + 1)
      u_sdram_model.memory_word_array[memory_word_index] = 32'h1000_0000 + memory_word_index;

    repeat (4) @(posedge clock);
    @(negedge clock);
    reset = 1'b0;

    // 32-bit、INCR、ARLEN=7、32B对齐：一条AXI事务映射为一条原生SDRAM BL8。
    read_command_count_before_transaction      = sdram_read_command_count;
    terminate_command_count_before_transaction = sdram_burst_terminate_command_count;
    issue_read_transaction(32'ha000_0000, 8'd7, 3'd2, 2'd1, 4'ha);
    receive_read_response(8, 32'h1000_0000, 4'ha, 20);
    assert (sdram_read_command_count - read_command_count_before_transaction == 1)
      else $fatal(1, "native BL8 transaction emitted %0d SDRAM READ commands",
                  sdram_read_command_count - read_command_count_before_transaction);
    assert (sdram_burst_terminate_command_count - terminate_command_count_before_transaction == 0)
      else $fatal(1, "native BL8 transaction emitted BURST TERMINATE");

    // 当前RV32默认8B cacheline对应2-beat AXI读。控制器应只发一条SDRAM READ，
    // 连续接收两个word后用BURST TERMINATE丢弃Mode Register BL8的剩余beat。
    read_command_count_before_transaction      = sdram_read_command_count;
    terminate_command_count_before_transaction = sdram_burst_terminate_command_count;
    issue_read_transaction(32'ha000_0040, 8'd1, 3'd2, 2'd1, 4'h2);
    receive_read_response(2, 32'h1000_0010, 4'h2, 0);
    assert (sdram_read_command_count - read_command_count_before_transaction == 1)
      else $fatal(1, "2-beat transaction emitted %0d SDRAM READ commands",
                  sdram_read_command_count - read_command_count_before_transaction);
    assert (sdram_burst_terminate_command_count - terminate_command_count_before_transaction == 1)
      else $fatal(1, "2-beat transaction emitted %0d BURST TERMINATE commands",
                  sdram_burst_terminate_command_count - terminate_command_count_before_transaction);

    // 64B对齐cacheline被拆成两个连续BL8。两个物理段共享同一个AXI ID，只有
    // 第16个AXI response beat携带RLAST。
    read_command_count_before_transaction      = sdram_read_command_count;
    terminate_command_count_before_transaction = sdram_burst_terminate_command_count;
    issue_read_transaction(32'ha000_0100, 8'd15, 3'd2, 2'd1, 4'h6);
    receive_read_response(16, 32'h1000_0040, 4'h6, 20);
    assert (sdram_read_command_count - read_command_count_before_transaction == 2)
      else $fatal(1, "64B aligned transaction emitted %0d SDRAM READ commands",
                  sdram_read_command_count - read_command_count_before_transaction);
    assert (sdram_burst_terminate_command_count - terminate_command_count_before_transaction == 0)
      else $fatal(1, "64B aligned transaction emitted BURST TERMINATE");

    // 从32B边界内偏移4B开始的64B事务被分为7+8+1 beat三个物理连续读段，
    // 首尾短段各产生一次BURST TERMINATE，中间完整BL8自然结束。
    read_command_count_before_transaction      = sdram_read_command_count;
    terminate_command_count_before_transaction = sdram_burst_terminate_command_count;
    issue_read_transaction(32'ha000_0124, 8'd15, 3'd2, 2'd1, 4'h7);
    receive_read_response(16, 32'h1000_0049, 4'h7, 20);
    assert (sdram_read_command_count - read_command_count_before_transaction == 3)
      else $fatal(1, "64B crossing transaction emitted %0d SDRAM READ commands",
                  sdram_read_command_count - read_command_count_before_transaction);
    assert (sdram_burst_terminate_command_count - terminate_command_count_before_transaction == 2)
      else $fatal(1, "64B crossing transaction emitted %0d BURST TERMINATE commands",
                  sdram_burst_terminate_command_count - terminate_command_count_before_transaction);

    // 16B cacheline对应4-beat AXI读，应合并成一条物理连续读，并在第4 beat后终止。
    read_command_count_before_transaction      = sdram_read_command_count;
    terminate_command_count_before_transaction = sdram_burst_terminate_command_count;
    issue_read_transaction(32'ha000_0080, 8'd3, 3'd2, 2'd1, 4'h5);
    receive_read_response(4, 32'h1000_0020, 4'h5, 0);
    assert (sdram_read_command_count - read_command_count_before_transaction == 1)
      else $fatal(1, "4-beat transaction emitted %0d SDRAM READ commands",
                  sdram_read_command_count - read_command_count_before_transaction);
    assert (sdram_burst_terminate_command_count - terminate_command_count_before_transaction == 1)
      else $fatal(1, "4-beat transaction emitted %0d BURST TERMINATE commands",
                  sdram_burst_terminate_command_count - terminate_command_count_before_transaction);

    // 4-beat事务若从32B边界内第6个word开始，必须拆成2+2两个物理段，避免
    // SDRAM BL8在边界内回绕后返回错误地址的数据。
    read_command_count_before_transaction      = sdram_read_command_count;
    terminate_command_count_before_transaction = sdram_burst_terminate_command_count;
    issue_read_transaction(32'ha000_0098, 8'd3, 3'd2, 2'd1, 4'h8);
    receive_read_response(4, 32'h1000_0026, 4'h8, 0);
    assert (sdram_read_command_count - read_command_count_before_transaction == 2)
      else $fatal(1, "boundary-crossing 4-beat transaction emitted %0d SDRAM READ commands",
                  sdram_read_command_count - read_command_count_before_transaction);
    assert (sdram_burst_terminate_command_count - terminate_command_count_before_transaction == 2)
      else $fatal(1, "boundary-crossing 4-beat transaction emitted %0d BURST TERMINATE commands",
                  sdram_burst_terminate_command_count - terminate_command_count_before_transaction);

    $display("sdram_axi_transaction_classification_tb: PASS");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "testbench timeout");
  end

endmodule
