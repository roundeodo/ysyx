module axi4_delayer #(
`ifdef YSYX_DEVICE_TIMING_MODE
    parameter integer DEVICE_TIMING_MODE = `YSYX_DEVICE_TIMING_MODE,
`else
    parameter integer DEVICE_TIMING_MODE = 1,
`endif
`ifdef YSYX_SIM_CPU_FREQ_MHZ
    parameter [63:0] CPU_FREQUENCY_HZ = 64'd1000000 * `YSYX_SIM_CPU_FREQ_MHZ,
`else
    parameter [63:0] CPU_FREQUENCY_HZ = 100_000_000,
`endif
    parameter [63:0] DEVICE_FREQUENCY_HZ = 100_000_000,
`ifdef YSYX_SIM_CPU_FREQ_MHZ
    // 与 CPU 本地 CLINT 共享频率输入；外设参考频率固定为 100 MHz。
    parameter [63:0] PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED =
        (64'd1 << FREQUENCY_RATIO_SCALE_SHIFT) * `YSYX_SIM_CPU_FREQ_MHZ / 64'd100,
`else
    parameter [63:0] PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED = 64'd3037,
`endif
    parameter integer FREQUENCY_RATIO_SCALE_SHIFT = 10,
    parameter integer READ_RESPONSE_BUFFER_DEPTH = 16,
    parameter integer READ_RESPONSE_BUFFER_ADDR_WIDTH = 4
) (
    input  clock,
    input  reset,
    output device_clock_o,

    output reg        in_arready,
    input             in_arvalid,
    input      [ 3:0] in_arid,
    input      [31:0] in_araddr,
    input      [ 7:0] in_arlen,
    input      [ 2:0] in_arsize,
    input      [ 1:0] in_arburst,
    input             in_rready,
    output reg        in_rvalid,
    output reg [ 3:0] in_rid,
    output reg [31:0] in_rdata,
    output reg [ 1:0] in_rresp,
    output reg        in_rlast,

    output reg        in_awready,
    input             in_awvalid,
    input      [ 3:0] in_awid,
    input      [31:0] in_awaddr,
    input      [ 7:0] in_awlen,
    input      [ 2:0] in_awsize,
    input      [ 1:0] in_awburst,
    output reg        in_wready,
    input             in_wvalid,
    input      [31:0] in_wdata,
    input      [ 3:0] in_wstrb,
    input             in_wlast,
    input             in_bready,
    output reg        in_bvalid,
    output reg [ 3:0] in_bid,
    output reg [ 1:0] in_bresp,

    input             out_arready,
    output reg        out_arvalid,
    output reg [ 3:0] out_arid,
    output reg [31:0] out_araddr,
    output reg [ 7:0] out_arlen,
    output reg [ 2:0] out_arsize,
    output reg [ 1:0] out_arburst,
    output reg        out_rready,
    input             out_rvalid,
    input      [ 3:0] out_rid,
    input      [31:0] out_rdata,
    input      [ 1:0] out_rresp,
    input             out_rlast,

    input             out_awready,
    output reg        out_awvalid,
    output reg [ 3:0] out_awid,
    output reg [31:0] out_awaddr,
    output reg [ 7:0] out_awlen,
    output reg [ 2:0] out_awsize,
    output reg [ 1:0] out_awburst,
    input             out_wready,
    output reg        out_wvalid,
    output reg [31:0] out_wdata,
    output reg [ 3:0] out_wstrb,
    output reg        out_wlast,
    output reg        out_bready,
    input             out_bvalid,
    input      [ 3:0] out_bid,
    input      [ 1:0] out_bresp
);


  generate
    if (DEVICE_TIMING_MODE == 0) begin : g_legacy
      assign device_clock_o = clock;
      axi4_delayer_legacy #(
          .PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED(PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED),
          .FREQUENCY_RATIO_SCALE_SHIFT(FREQUENCY_RATIO_SCALE_SHIFT),
          .READ_RESPONSE_BUFFER_DEPTH(READ_RESPONSE_BUFFER_DEPTH),
          .READ_RESPONSE_BUFFER_ADDR_WIDTH(READ_RESPONSE_BUFFER_ADDR_WIDTH)
      ) u_legacy (
          .*
      );
    end else begin : g_device
      wire device_step;
      device_clock #(
          .CPU_FREQUENCY_HZ(CPU_FREQUENCY_HZ),
          .DEVICE_FREQUENCY_HZ(DEVICE_FREQUENCY_HZ)
      ) u_clock (
          .clock(clock),
          .reset(reset),
          .device_clock_o(device_clock_o),
          .device_step_o(device_step)
      );

      // One read and one write transaction may coexist. Request payload stays
      // with the CPU until a device edge accepts it; no extra request FIFO.
      reg read_active_q;
      reg write_address_accepted_q;
      reg write_last_accepted_q;

      always @(*) begin
        out_arid    = in_arid;
        out_araddr  = in_araddr;
        out_arlen   = in_arlen;
        out_arsize  = in_arsize;
        out_arburst = in_arburst;
        out_arvalid = in_arvalid && !read_active_q;
        in_arready  = device_step && out_arready && !read_active_q;

        out_awid    = in_awid;
        out_awaddr  = in_awaddr;
        out_awlen   = in_awlen;
        out_awsize  = in_awsize;
        out_awburst = in_awburst;
        out_awvalid = in_awvalid && !write_address_accepted_q;
        in_awready  = device_step && out_awready && !write_address_accepted_q;

        out_wdata  = in_wdata;
        out_wstrb  = in_wstrb;
        out_wlast  = in_wlast;
        out_wvalid = in_wvalid && !write_last_accepted_q;
        in_wready  = device_step && out_wready && !write_last_accepted_q;
      end

      // The existing 16-beat R capacity absorbs CPU backpressure. An empty
      // queue bypasses on a device edge; a stalled beat is captured once.
      reg [38:0] read_response_array[0:READ_RESPONSE_BUFFER_DEPTH-1];
      reg [READ_RESPONSE_BUFFER_ADDR_WIDTH-1:0] read_index_q, write_index_q;
      reg [READ_RESPONSE_BUFFER_ADDR_WIDTH:0] read_count_q;
      wire read_buffer_present = read_count_q != 0;
      wire read_buffer_pop = read_buffer_present && in_rready;
      wire read_direct_present = !read_buffer_present && device_step && read_active_q && out_rvalid;
      wire read_direct_consumed = read_direct_present && in_rready;
      wire read_buffer_push = device_step && out_rvalid && out_rready && !read_direct_consumed;

      always @(*) begin
        out_rready = read_active_q &&
            (!read_count_q[READ_RESPONSE_BUFFER_ADDR_WIDTH] || read_buffer_pop);
        in_rvalid = read_buffer_present || read_direct_present;
        {in_rid, in_rdata, in_rresp, in_rlast} = read_buffer_present ?
            read_response_array[read_index_q] : {out_rid, out_rdata, out_rresp, out_rlast};
      end

      always @(posedge clock) begin
        if (reset) begin
          read_count_q  <= 0;
          read_index_q  <= 0;
          write_index_q <= 0;
        end else begin
          if (read_buffer_push) begin
            read_response_array[write_index_q] <= {out_rid, out_rdata, out_rresp, out_rlast};
            write_index_q <= write_index_q + 1'b1;
          end
          if (read_buffer_pop) read_index_q <= read_index_q + 1'b1;
          case ({
            read_buffer_push, read_buffer_pop
          })
            2'b10:   read_count_q <= read_count_q + 1'b1;
            2'b01:   read_count_q <= read_count_q - 1'b1;
            default: ;
          endcase
        end
      end

      // One B response, with the same empty bypass and stall capture as R.
      reg write_response_present_q;
      reg [5:0] write_response_q;
      wire write_inputs_accepted = write_address_accepted_q && write_last_accepted_q;
      wire write_direct_present = !write_response_present_q && device_step &&
          out_bvalid && write_inputs_accepted;
      wire write_response_pop = write_response_present_q && in_bready;
      wire write_response_push = device_step && out_bvalid && out_bready &&
          !(write_direct_present && in_bready);

      always @(*) begin
        out_bready = write_inputs_accepted && (!write_response_present_q || write_response_pop);
        in_bvalid = write_response_present_q || write_direct_present;
        {in_bid, in_bresp} = write_response_present_q ? write_response_q : {out_bid, out_bresp};
      end

      always @(posedge clock) begin
        if (reset) begin
          write_response_present_q <= 1'b0;
          write_response_q <= 0;
        end else begin
          if (write_response_pop) write_response_present_q <= 1'b0;
          if (write_response_push) begin
            write_response_present_q <= 1'b1;
            write_response_q <= {out_bid, out_bresp};
          end
        end
      end

      // Transaction ownership ends only when the CPU consumes the last reply.
      always @(posedge clock) begin
        if (reset) begin
          read_active_q <= 1'b0;
          write_address_accepted_q <= 1'b0;
          write_last_accepted_q <= 1'b0;
        end else begin
          if (in_arvalid && in_arready) read_active_q <= 1'b1;
          if (in_rvalid && in_rready && in_rlast) read_active_q <= 1'b0;
          if (in_awvalid && in_awready) write_address_accepted_q <= 1'b1;
          if (in_wvalid && in_wready && in_wlast) write_last_accepted_q <= 1'b1;
          if (in_bvalid && in_bready) begin
            write_address_accepted_q <= 1'b0;
            write_last_accepted_q <= 1'b0;
          end
        end
      end
    end
  endgenerate

  initial begin
    if (DEVICE_TIMING_MODE < 0 || DEVICE_TIMING_MODE > 1 ||
        READ_RESPONSE_BUFFER_DEPTH != (1 << READ_RESPONSE_BUFFER_ADDR_WIDTH))
      $fatal(1, "invalid device timing mode or read response queue depth");
  end
endmodule


// Historical response-scaling model, retained only for explicit reproduction.
module axi4_delayer_legacy #(
`ifdef YSYX_SIM_CPU_FREQ_MHZ
    // 与 CPU 本地 CLINT 共享频率输入；外设参考频率固定为 100 MHz。
    parameter [63:0] PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED =
        (64'd1 << FREQUENCY_RATIO_SCALE_SHIFT) * `YSYX_SIM_CPU_FREQ_MHZ / 64'd100,
`else
    parameter [63:0] PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED = 64'd3037,
`endif
    parameter integer FREQUENCY_RATIO_SCALE_SHIFT = 10,
    parameter integer READ_RESPONSE_BUFFER_DEPTH = 16,
    parameter integer READ_RESPONSE_BUFFER_ADDR_WIDTH = 4
) (
    input         clock,
    input         reset,

    output reg        in_arready,
    input             in_arvalid,
    input      [ 3:0] in_arid,
    input      [31:0] in_araddr,
    input      [ 7:0] in_arlen,
    input      [ 2:0] in_arsize,
    input      [ 1:0] in_arburst,
    input             in_rready,
    output reg        in_rvalid,
    output reg [ 3:0] in_rid,
    output reg [31:0] in_rdata,
    output reg [ 1:0] in_rresp,
    output reg        in_rlast,

    output reg        in_awready,
    input             in_awvalid,
    input      [ 3:0] in_awid,
    input      [31:0] in_awaddr,
    input      [ 7:0] in_awlen,
    input      [ 2:0] in_awsize,
    input      [ 1:0] in_awburst,
    output reg        in_wready,
    input             in_wvalid,
    input      [31:0] in_wdata,
    input      [ 3:0] in_wstrb,
    input             in_wlast,
    input             in_bready,
    output reg        in_bvalid,
    output reg [ 3:0] in_bid,
    output reg [ 1:0] in_bresp,

    input             out_arready,
    output reg        out_arvalid,
    output reg [ 3:0] out_arid,
    output reg [31:0] out_araddr,
    output reg [ 7:0] out_arlen,
    output reg [ 2:0] out_arsize,
    output reg [ 1:0] out_arburst,
    output reg        out_rready,
    input             out_rvalid,
    input      [ 3:0] out_rid,
    input      [31:0] out_rdata,
    input      [ 1:0] out_rresp,
    input             out_rlast,

    input             out_awready,
    output reg        out_awvalid,
    output reg [ 3:0] out_awid,
    output reg [31:0] out_awaddr,
    output reg [ 7:0] out_awlen,
    output reg [ 2:0] out_awsize,
    output reg [ 1:0] out_awburst,
    input             out_wready,
    output reg        out_wvalid,
    output reg [31:0] out_wdata,
    output reg [ 3:0] out_wstrb,
    output reg        out_wlast,
    output reg        out_bready,
    input             out_bvalid,
    input      [ 3:0] out_bid,
    input      [ 1:0] out_bresp
);

  localparam [63:0] FREQUENCY_RATIO_SCALE =
      64'd1 << FREQUENCY_RATIO_SCALE_SHIFT;
  localparam [63:0] FREQUENCY_RATIO_SCALED =
      PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED;

`ifndef SYNTHESIS
  initial begin
    if (FREQUENCY_RATIO_SCALE_SHIFT <= 0) begin
      $fatal(1, "FREQUENCY_RATIO_SCALE_SHIFT must be greater than zero");
    end

    if (FREQUENCY_RATIO_SCALED < FREQUENCY_RATIO_SCALE) begin
      $fatal(1, "processor/device frequency ratio must be at least one");
    end

    if (READ_RESPONSE_BUFFER_DEPTH !=
        (1 << READ_RESPONSE_BUFFER_ADDR_WIDTH)) begin
      $fatal(1, "read response buffer depth must match its address width");
    end
  end
`endif

  // ========================================================================
  // Read transaction timing
  // ========================================================================

  // 读计时从ARVALID第一次出现开始，而不是从AR握手开始。这样ARREADY造成的等待
  // 也属于设备访问延迟，符合：(t_response - t_start) * frequency_ratio。
  reg         read_transaction_active_q;
  reg         read_transaction_active_d;
  reg         read_address_handshake_occurred_q;
  reg         read_address_handshake_occurred_d;
  reg  [31:0] read_device_elapsed_cycle_count_q;
  reg  [31:0] read_device_elapsed_cycle_count_d;
  reg  [63:0] read_calibrated_elapsed_cycle_scaled_q;
  reg  [63:0] read_calibrated_elapsed_cycle_scaled_d;
  reg  [63:0] read_frequency_ratio_fraction_remainder_q;
  reg  [63:0] read_frequency_ratio_fraction_remainder_d;

  wire read_transaction_start_present =
      !read_transaction_active_q && in_arvalid;
  wire downstream_read_address_handshake_occurred =
      out_arvalid && out_arready;
  wire upstream_read_response_handshake_occurred =
      in_rvalid && in_rready;

  // 当前周期若发生下游R握手，它距离事务起点已经经过的CPU周期数。
  wire [31:0] current_read_device_elapsed_cycle_count =
      read_device_elapsed_cycle_count_q + 32'd1;
  wire [63:0] current_read_calibrated_total_cycle_scaled =
      read_calibrated_elapsed_cycle_scaled_q +
      FREQUENCY_RATIO_SCALED +
      read_frequency_ratio_fraction_remainder_q;
  wire [31:0] current_read_response_scheduled_cycle =
      current_read_calibrated_total_cycle_scaled[
          FREQUENCY_RATIO_SCALE_SHIFT + 31:FREQUENCY_RATIO_SCALE_SHIFT];
  wire [63:0] next_read_frequency_ratio_fraction_remainder =
      current_read_calibrated_total_cycle_scaled -
      ({32'd0, current_read_response_scheduled_cycle} <<
       FREQUENCY_RATIO_SCALE_SHIFT);

  // ========================================================================
  // Read response buffer
  // ========================================================================

  // 每个R beat都保存自己的目标返回周期。SDRAM可以连续返回burst数据，而上游
  // 只能在各自校准后的时刻看到这些beat。16项能够完整保存64B/32-bit事务。
  reg [ 3:0] read_response_id_array
      [0:READ_RESPONSE_BUFFER_DEPTH-1];
  reg [31:0] read_response_data_array
      [0:READ_RESPONSE_BUFFER_DEPTH-1];
  reg [ 1:0] read_response_status_array
      [0:READ_RESPONSE_BUFFER_DEPTH-1];
  reg        read_response_last_array
      [0:READ_RESPONSE_BUFFER_DEPTH-1];
  reg [31:0] read_response_scheduled_cycle_array
      [0:READ_RESPONSE_BUFFER_DEPTH-1];

  reg [READ_RESPONSE_BUFFER_ADDR_WIDTH-1:0]
      read_response_write_index_q;
  reg [READ_RESPONSE_BUFFER_ADDR_WIDTH-1:0]
      read_response_write_index_d;
  reg [READ_RESPONSE_BUFFER_ADDR_WIDTH-1:0]
      read_response_read_index_q;
  reg [READ_RESPONSE_BUFFER_ADDR_WIDTH-1:0]
      read_response_read_index_d;
  reg [READ_RESPONSE_BUFFER_ADDR_WIDTH:0]
      read_response_count_q;
  reg [READ_RESPONSE_BUFFER_ADDR_WIDTH:0]
      read_response_count_d;

  wire read_response_buffer_present = read_response_count_q != 0;
  wire read_response_buffer_head_due =
      read_response_buffer_present &&
      current_read_device_elapsed_cycle_count >=
      read_response_scheduled_cycle_array[read_response_read_index_q];

  // ratio=1或设备本身已经足够慢时，响应可在同一周期直接返回，不强制增加
  // 一个FIFO周期；如果上游反压，下游保持VALID和payload即可。
  wire downstream_read_response_due =
      current_read_device_elapsed_cycle_count >=
      current_read_response_scheduled_cycle;
  wire read_response_direct_path_selected =
      read_transaction_active_q &&
      !read_response_buffer_present &&
      out_rvalid && downstream_read_response_due;

  wire read_response_buffer_pop =
      read_response_buffer_head_due && in_rready;
  wire read_response_buffer_has_space =
      !read_response_count_q[READ_RESPONSE_BUFFER_ADDR_WIDTH] ||
      read_response_buffer_pop;
  wire downstream_read_response_handshake_occurred =
      out_rvalid && out_rready;
  wire read_response_buffer_push =
      downstream_read_response_handshake_occurred &&
      !read_response_direct_path_selected;

  // ------------------------------------------------------------------------
  // 第一段：读通道输出
  // ------------------------------------------------------------------------

  always @(*) begin
    out_arid    = in_arid;
    out_araddr  = in_araddr;
    out_arlen   = in_arlen;
    out_arsize  = in_arsize;
    out_arburst = in_arburst;

    out_arvalid = in_arvalid && !read_address_handshake_occurred_q;
    in_arready  = out_arready && !read_address_handshake_occurred_q;

    in_rvalid = 1'b0;
    in_rid    = 4'd0;
    in_rdata  = 32'd0;
    in_rresp  = 2'd0;
    in_rlast  = 1'b0;

    out_rready = 1'b0;

    if (read_response_buffer_present) begin
      in_rvalid = read_response_buffer_head_due;
      in_rid    = read_response_id_array[read_response_read_index_q];
      in_rdata  = read_response_data_array[read_response_read_index_q];
      in_rresp  = read_response_status_array[read_response_read_index_q];
      in_rlast  = read_response_last_array[read_response_read_index_q];

      out_rready = read_transaction_active_q &&
                   read_response_buffer_has_space;
    end else if (read_response_direct_path_selected) begin
      in_rvalid = out_rvalid;
      in_rid    = out_rid;
      in_rdata  = out_rdata;
      in_rresp  = out_rresp;
      in_rlast  = out_rlast;

      out_rready = in_rready;
    end else begin
      // 尚未到目标周期时先接收并保存，避免人为阻塞下游设备。
      out_rready = read_transaction_active_q &&
                   read_response_buffer_has_space;
    end
  end

  // ------------------------------------------------------------------------
  // 第二段：读事务和响应队列下一值
  // ------------------------------------------------------------------------

  always @(*) begin
    read_transaction_active_d                = read_transaction_active_q;
    read_address_handshake_occurred_d        = read_address_handshake_occurred_q;
    read_device_elapsed_cycle_count_d         = read_device_elapsed_cycle_count_q;
    read_calibrated_elapsed_cycle_scaled_d    = read_calibrated_elapsed_cycle_scaled_q;
    read_frequency_ratio_fraction_remainder_d =
        read_frequency_ratio_fraction_remainder_q;

    if (read_transaction_start_present) begin
      read_transaction_active_d              = 1'b1;
      read_address_handshake_occurred_d      = 1'b0;
      read_device_elapsed_cycle_count_d       = 32'd0;
      read_calibrated_elapsed_cycle_scaled_d  = 64'd0;
    end else if (read_transaction_active_q) begin
      read_device_elapsed_cycle_count_d =
          read_device_elapsed_cycle_count_q + 32'd1;
      read_calibrated_elapsed_cycle_scaled_d =
          read_calibrated_elapsed_cycle_scaled_q + FREQUENCY_RATIO_SCALED;
    end

    if (downstream_read_address_handshake_occurred) begin
      read_address_handshake_occurred_d = 1'b1;
    end

    if (downstream_read_response_handshake_occurred && out_rlast) begin
      read_frequency_ratio_fraction_remainder_d =
          next_read_frequency_ratio_fraction_remainder;
    end

    if (upstream_read_response_handshake_occurred && in_rlast) begin
      read_transaction_active_d              = 1'b0;
      read_address_handshake_occurred_d      = 1'b0;
      read_device_elapsed_cycle_count_d       = 32'd0;
      read_calibrated_elapsed_cycle_scaled_d  = 64'd0;
    end
  end

  always @(*) begin
    read_response_write_index_d = read_response_write_index_q;
    read_response_read_index_d  = read_response_read_index_q;
    read_response_count_d       = read_response_count_q;

    if (read_response_buffer_push) begin
      read_response_write_index_d = read_response_write_index_q + 1'b1;
    end

    if (read_response_buffer_pop) begin
      read_response_read_index_d = read_response_read_index_q + 1'b1;
    end

    case ({read_response_buffer_push, read_response_buffer_pop})
      2'b10: read_response_count_d = read_response_count_q + 1'b1;
      2'b01: read_response_count_d = read_response_count_q - 1'b1;
      default: ;
    endcase
  end

  // ------------------------------------------------------------------------
  // 第三段：读事务和响应队列寄存器更新
  // ------------------------------------------------------------------------

  always @(posedge clock) begin
    if (reset) begin
      read_transaction_active_q         <= 1'b0;
      read_address_handshake_occurred_q <= 1'b0;
    end else begin
      read_transaction_active_q         <= read_transaction_active_d;
      read_address_handshake_occurred_q <= read_address_handshake_occurred_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      read_device_elapsed_cycle_count_q      <= 32'd0;
      read_calibrated_elapsed_cycle_scaled_q <= 64'd0;
    end else begin
      read_device_elapsed_cycle_count_q      <= read_device_elapsed_cycle_count_d;
      read_calibrated_elapsed_cycle_scaled_q <=
          read_calibrated_elapsed_cycle_scaled_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      read_frequency_ratio_fraction_remainder_q <= 64'd0;
    end else begin
      read_frequency_ratio_fraction_remainder_q <=
          read_frequency_ratio_fraction_remainder_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      read_response_write_index_q <= {READ_RESPONSE_BUFFER_ADDR_WIDTH{1'b0}};
      read_response_read_index_q  <= {READ_RESPONSE_BUFFER_ADDR_WIDTH{1'b0}};
      read_response_count_q       <= {(READ_RESPONSE_BUFFER_ADDR_WIDTH + 1){1'b0}};
    end else begin
      read_response_write_index_q <= read_response_write_index_d;
      read_response_read_index_q  <= read_response_read_index_d;
      read_response_count_q       <= read_response_count_d;

      if (read_response_buffer_push) begin
        read_response_id_array[read_response_write_index_q] <= out_rid;
        read_response_data_array[read_response_write_index_q] <= out_rdata;
        read_response_status_array[read_response_write_index_q] <= out_rresp;
        read_response_last_array[read_response_write_index_q] <= out_rlast;
        read_response_scheduled_cycle_array[read_response_write_index_q] <=
            current_read_response_scheduled_cycle;
      end
    end
  end

  // ========================================================================
  // Write transaction timing
  // ========================================================================

  // AW和W相互独立，因此从二者中最早出现的VALID开始计时，并分别记录地址与
  // 最后一个数据beat是否已经握手。读写计时器彼此独立，允许两类事务并行。
  reg         write_transaction_active_q;
  reg         write_transaction_active_d;
  reg         write_address_handshake_occurred_q;
  reg         write_address_handshake_occurred_d;
  reg         write_data_last_handshake_occurred_q;
  reg         write_data_last_handshake_occurred_d;
  reg  [31:0] write_elapsed_cycle_count_q;
  reg  [31:0] write_elapsed_cycle_count_d;
  reg  [63:0] write_calibrated_elapsed_cycle_scaled_q;
  reg  [63:0] write_calibrated_elapsed_cycle_scaled_d;
  reg  [63:0] write_frequency_ratio_fraction_remainder_q;
  reg  [63:0] write_frequency_ratio_fraction_remainder_d;

  wire write_transaction_start_present =
      !write_transaction_active_q && (in_awvalid || in_wvalid);
  wire downstream_write_address_handshake_occurred =
      out_awvalid && out_awready;
  wire downstream_write_data_handshake_occurred =
      out_wvalid && out_wready;
  wire upstream_write_response_handshake_occurred =
      in_bvalid && in_bready;

  // A downstream W acceptance is acknowledged upstream only at its calibrated
  // deadline. Until then the master holds the payload and we suppress duplicates.
  reg         write_data_ack_pending_q;
  reg  [31:0] write_data_ack_cycle_q;
  reg         write_upstream_last_accepted_q;
  // Device work can overlap an inserted W acknowledgement delay. In particular,
  // do not stop AW progress or the final B latency just because W is pending.
  wire write_address_device_wait =
      !write_address_handshake_occurred_q && in_awvalid;
  wire write_data_device_wait =
      !write_data_last_handshake_occurred_q &&
      !write_data_ack_pending_q && in_wvalid;
  wire write_response_device_wait =
      write_address_handshake_occurred_q &&
      write_data_last_handshake_occurred_q && !write_response_present_q;

  // Producer gaps are already CPU time. Scale only device work, count a source
  // gap once, and never charge our own acknowledgement wait a second time.
  wire [63:0] write_time_increment_scaled =
      (write_address_device_wait || write_data_device_wait || write_response_device_wait)
      ? FREQUENCY_RATIO_SCALED
      : (write_data_ack_pending_q ? 64'd0 : FREQUENCY_RATIO_SCALE);

  wire [31:0] current_write_elapsed_cycle_count =
      write_elapsed_cycle_count_q + 32'd1;
  wire [63:0] current_write_calibrated_total_cycle_scaled =
      write_calibrated_elapsed_cycle_scaled_q +
      write_time_increment_scaled +
      write_frequency_ratio_fraction_remainder_q;
  wire [31:0] current_write_response_scheduled_cycle =
      current_write_calibrated_total_cycle_scaled[
          FREQUENCY_RATIO_SCALE_SHIFT + 31:FREQUENCY_RATIO_SCALE_SHIFT];
  wire [63:0] next_write_frequency_ratio_fraction_remainder =
      current_write_calibrated_total_cycle_scaled -
      ({32'd0, current_write_response_scheduled_cycle} <<
       FREQUENCY_RATIO_SCALE_SHIFT);

  // B通道每笔写事务只有一个响应，一个寄存器即可解耦下游响应和上游目标时刻。
  reg         write_response_present_q;
  reg         write_response_present_d;
  reg  [ 3:0] write_response_id_q;
  reg  [ 3:0] write_response_id_d;
  reg  [ 1:0] write_response_status_q;
  reg  [ 1:0] write_response_status_d;
  reg  [31:0] write_response_scheduled_cycle_q;
  reg  [31:0] write_response_scheduled_cycle_d;

  wire write_response_buffer_due =
      write_response_present_q &&
      current_write_elapsed_cycle_count >=
      write_response_scheduled_cycle_q;
  wire downstream_write_response_due =
      current_write_elapsed_cycle_count >=
      current_write_response_scheduled_cycle;
  wire write_response_direct_path_selected =
      write_transaction_active_q &&
      !write_response_present_q &&
      out_bvalid && downstream_write_response_due && write_upstream_last_accepted_q;
  wire downstream_write_response_handshake_occurred =
      out_bvalid && out_bready;

  always @(posedge clock) begin
    if (reset || upstream_write_response_handshake_occurred) begin
      write_data_ack_pending_q       <= 1'b0;
      write_data_ack_cycle_q         <= 32'd0;
      write_upstream_last_accepted_q <= 1'b0;
    end else begin
      if (downstream_write_data_handshake_occurred && !in_wready) begin
        write_data_ack_pending_q <= 1'b1;
        write_data_ack_cycle_q   <= current_write_response_scheduled_cycle;
      end
      if (in_wvalid && in_wready) begin
        write_data_ack_pending_q <= 1'b0;
        if (in_wlast) write_upstream_last_accepted_q <= 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------------
  // 第一段：写通道输出
  // ------------------------------------------------------------------------

  always @(*) begin
    out_awid    = in_awid;
    out_awaddr  = in_awaddr;
    out_awlen   = in_awlen;
    out_awsize  = in_awsize;
    out_awburst = in_awburst;
    out_awvalid = in_awvalid && !write_address_handshake_occurred_q;
    in_awready  = out_awready && !write_address_handshake_occurred_q;

    out_wdata  = in_wdata;
    out_wstrb  = in_wstrb;
    out_wlast  = in_wlast;
    out_wvalid = in_wvalid && !write_data_last_handshake_occurred_q &&
                 !write_data_ack_pending_q;
    in_wready = write_data_ack_pending_q ?
        (current_write_elapsed_cycle_count >= write_data_ack_cycle_q) :
        (out_wready && !write_data_last_handshake_occurred_q &&
         current_write_elapsed_cycle_count >= current_write_response_scheduled_cycle);

    in_bvalid  = 1'b0;
    in_bid     = 4'd0;
    in_bresp   = 2'd0;
    out_bready = 1'b0;

    if (write_response_present_q) begin
      in_bvalid = write_response_buffer_due && write_upstream_last_accepted_q;
      in_bid    = write_response_id_q;
      in_bresp  = write_response_status_q;
    end else if (write_response_direct_path_selected) begin
      in_bvalid  = out_bvalid && write_upstream_last_accepted_q;
      in_bid     = out_bid;
      in_bresp   = out_bresp;
      out_bready = in_bready && write_upstream_last_accepted_q;
    end else begin
      out_bready = write_transaction_active_q;
    end
  end

  // ------------------------------------------------------------------------
  // 第二段：写事务和B响应下一值
  // ------------------------------------------------------------------------

  always @(*) begin
    write_transaction_active_d                = write_transaction_active_q;
    write_address_handshake_occurred_d        = write_address_handshake_occurred_q;
    write_data_last_handshake_occurred_d      = write_data_last_handshake_occurred_q;
    write_elapsed_cycle_count_d         = write_elapsed_cycle_count_q;
    write_calibrated_elapsed_cycle_scaled_d    = write_calibrated_elapsed_cycle_scaled_q;
    write_frequency_ratio_fraction_remainder_d =
        write_frequency_ratio_fraction_remainder_q;

    write_response_present_d         = write_response_present_q;
    write_response_id_d              = write_response_id_q;
    write_response_status_d          = write_response_status_q;
    write_response_scheduled_cycle_d = write_response_scheduled_cycle_q;

    if (write_transaction_start_present) begin
      write_transaction_active_d              = 1'b1;
      write_address_handshake_occurred_d      = 1'b0;
      write_data_last_handshake_occurred_d    = 1'b0;
      write_elapsed_cycle_count_d       = 32'd0;
      write_calibrated_elapsed_cycle_scaled_d  = 64'd0;
    end else if (write_transaction_active_q) begin
      write_elapsed_cycle_count_d =
          write_elapsed_cycle_count_q + 32'd1;
      write_calibrated_elapsed_cycle_scaled_d =
          write_calibrated_elapsed_cycle_scaled_q + write_time_increment_scaled;
    end

    if (downstream_write_address_handshake_occurred) begin
      write_address_handshake_occurred_d = 1'b1;
    end

    if (downstream_write_data_handshake_occurred && out_wlast) begin
      write_data_last_handshake_occurred_d = 1'b1;
    end

    if (downstream_write_response_handshake_occurred) begin
      write_frequency_ratio_fraction_remainder_d =
          next_write_frequency_ratio_fraction_remainder;

      if (!write_response_direct_path_selected) begin
        write_response_present_d         = 1'b1;
        write_response_id_d              = out_bid;
        write_response_status_d          = out_bresp;
        write_response_scheduled_cycle_d =
            current_write_response_scheduled_cycle;
      end
    end

    if (upstream_write_response_handshake_occurred) begin
      write_transaction_active_d              = 1'b0;
      write_address_handshake_occurred_d      = 1'b0;
      write_data_last_handshake_occurred_d    = 1'b0;
      write_elapsed_cycle_count_d       = 32'd0;
      write_calibrated_elapsed_cycle_scaled_d  = 64'd0;
      write_response_present_d                = 1'b0;
    end
  end

  // ------------------------------------------------------------------------
  // 第三段：写事务和B响应寄存器更新
  // ------------------------------------------------------------------------

  always @(posedge clock) begin
    if (reset) begin
      write_transaction_active_q           <= 1'b0;
      write_address_handshake_occurred_q   <= 1'b0;
      write_data_last_handshake_occurred_q <= 1'b0;
    end else begin
      write_transaction_active_q           <= write_transaction_active_d;
      write_address_handshake_occurred_q   <= write_address_handshake_occurred_d;
      write_data_last_handshake_occurred_q <=
          write_data_last_handshake_occurred_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      write_elapsed_cycle_count_q         <= 32'd0;
      write_calibrated_elapsed_cycle_scaled_q    <= 64'd0;
      write_frequency_ratio_fraction_remainder_q <= 64'd0;
    end else begin
      write_elapsed_cycle_count_q      <= write_elapsed_cycle_count_d;
      write_calibrated_elapsed_cycle_scaled_q <=
          write_calibrated_elapsed_cycle_scaled_d;
      write_frequency_ratio_fraction_remainder_q <=
          write_frequency_ratio_fraction_remainder_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      write_response_present_q         <= 1'b0;
      write_response_id_q              <= 4'd0;
      write_response_status_q          <= 2'd0;
      write_response_scheduled_cycle_q <= 32'd0;
    end else begin
      write_response_present_q         <= write_response_present_d;
      write_response_id_q              <= write_response_id_d;
      write_response_status_q          <= write_response_status_d;
      write_response_scheduled_cycle_q <= write_response_scheduled_cycle_d;
    end
  end

`ifndef SYNTHESIS
  always @(posedge clock) begin
    if (!reset) begin
      if (read_response_count_q[READ_RESPONSE_BUFFER_ADDR_WIDTH] &&
          |read_response_count_q[READ_RESPONSE_BUFFER_ADDR_WIDTH-1:0]) begin
        $fatal(1, "AXI delayer read response buffer overflow");
      end

      if (downstream_read_response_handshake_occurred &&
          !read_transaction_active_q) begin
        $fatal(1, "AXI read response accepted without an active transaction");
      end

      if (downstream_write_response_handshake_occurred &&
          !write_transaction_active_q) begin
        $fatal(1, "AXI write response accepted without an active transaction");
      end
    end
  end
`endif

endmodule
