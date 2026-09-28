module apb_delayer #(
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
    parameter [63:0] PROCESSOR_TO_PERIPHERAL_FREQUENCY_RATIO_SCALED =
        (64'd1 << FREQUENCY_RATIO_SCALE_SHIFT) * `YSYX_SIM_CPU_FREQ_MHZ / 64'd100,
`else
    parameter [63:0] PROCESSOR_TO_PERIPHERAL_FREQUENCY_RATIO_SCALED = 64'd3037,
`endif
    parameter integer FREQUENCY_RATIO_SCALE_SHIFT = 10
) (
    input             clock,
    input             reset,
    output            device_clock_o,
    input      [31:0] in_paddr,
    input             in_psel,
    input             in_penable,
    input      [ 2:0] in_pprot,
    input             in_pwrite,
    input      [31:0] in_pwdata,
    input      [ 3:0] in_pstrb,
    output reg        in_pready,
    output reg [31:0] in_prdata,
    output reg        in_pslverr,

    output reg [31:0] out_paddr,
    output reg        out_psel,
    output reg        out_penable,
    output reg [ 2:0] out_pprot,
    output reg        out_pwrite,
    output reg [31:0] out_pwdata,
    output reg [ 3:0] out_pstrb,
    input             out_pready,
    input      [31:0] out_prdata,
    input             out_pslverr
);


  generate
    if (DEVICE_TIMING_MODE == 0) begin : g_legacy
      assign device_clock_o = clock;
      apb_delayer_legacy #(
          .PROCESSOR_TO_PERIPHERAL_FREQUENCY_RATIO_SCALED(PROCESSOR_TO_PERIPHERAL_FREQUENCY_RATIO_SCALED),
          .FREQUENCY_RATIO_SCALE_SHIFT(FREQUENCY_RATIO_SCALE_SHIFT)
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

      localparam [1:0] IDLE = 0, SETUP = 1, ACCESS = 2;
      reg [1:0] state_q, state_d;
      reg [71:0] request_q;
      wire setup_present = in_psel && !in_penable;

      // Capture fast-side setup if it misses a device edge. At an aligned edge
      // setup goes straight through; ACCESS completes without a response stage.
      always @(*) begin
        {out_paddr, out_pprot, out_pwrite, out_pwdata, out_pstrb} =
            (state_q == IDLE) ? {in_paddr, in_pprot, in_pwrite, in_pwdata, in_pstrb} : request_q;
        out_psel = (state_q != IDLE) || setup_present;
        out_penable = state_q == ACCESS;
        in_prdata = out_prdata;
        in_pslverr = out_pslverr;
        in_pready = (state_q == ACCESS) && device_step && out_pready;
      end

      always @(*) begin
        state_d = state_q;
        case (state_q)
          IDLE: begin
            if (setup_present) state_d = device_step ? ACCESS : SETUP;
          end
          SETUP: begin
            if (device_step) state_d = ACCESS;
          end
          ACCESS: begin
            if (device_step && out_pready) state_d = IDLE;
          end
          default: state_d = IDLE;
        endcase
      end

      always @(posedge clock) begin
        if (reset) begin
          state_q   <= IDLE;
          request_q <= 0;
        end else begin
          state_q <= state_d;
          if (state_q == IDLE && setup_present)
            request_q <= {in_paddr, in_pprot, in_pwrite, in_pwdata, in_pstrb};
        end
      end
    end
  endgenerate

  initial begin
    if (DEVICE_TIMING_MODE < 0 || DEVICE_TIMING_MODE > 1) $fatal(1, "invalid device timing mode");
  end
endmodule


// Historical response-scaling model, retained only for explicit reproduction.
module apb_delayer_legacy #(
`ifdef YSYX_SIM_CPU_FREQ_MHZ
    // 与 CPU 本地 CLINT 共享频率输入；外设参考频率固定为 100 MHz。
    parameter [63:0] PROCESSOR_TO_PERIPHERAL_FREQUENCY_RATIO_SCALED =
        (64'd1 << FREQUENCY_RATIO_SCALE_SHIFT) * `YSYX_SIM_CPU_FREQ_MHZ / 64'd100,
`else
    parameter [63:0] PROCESSOR_TO_PERIPHERAL_FREQUENCY_RATIO_SCALED = 64'd3037,
`endif
    parameter integer FREQUENCY_RATIO_SCALE_SHIFT = 10
) (
    input         clock,
    input         reset,
    input  [31:0] in_paddr,
    input         in_psel,
    input         in_penable,
    input  [ 2:0] in_pprot,
    input         in_pwrite,
    input  [31:0] in_pwdata,
    input  [ 3:0] in_pstrb,
    output reg        in_pready,
    output reg [31:0] in_prdata,
    output reg        in_pslverr,

    output reg [31:0] out_paddr,
    output reg        out_psel,
    output reg        out_penable,
    output reg [ 2:0] out_pprot,
    output reg        out_pwrite,
    output reg [31:0] out_pwdata,
    output reg [ 3:0] out_pstrb,
    input         out_pready,
    input  [31:0] out_prdata,
    input         out_pslverr
);

  localparam [1:0] APB_WAIT_REQUEST_STATE = 2'd0;
  localparam [1:0] APB_WAIT_DEVICE_RESPONSE_STATE = 2'd1;
  localparam [1:0] APB_DELAY_RESPONSE_STATE = 2'd2;
  localparam [63:0] FREQUENCY_RATIO_SCALE = 64'd1 << FREQUENCY_RATIO_SCALE_SHIFT;
  localparam [63:0] FREQUENCY_RATIO_SCALED = PROCESSOR_TO_PERIPHERAL_FREQUENCY_RATIO_SCALED;

  reg  [ 1:0] apb_delay_state_q;
  reg  [ 1:0] apb_delay_state_d;

  // 从APB setup开始，到下游设备返回响应所经过的CPU周期数。
  reg  [31:0] device_elapsed_cycle_count_q;
  reg  [31:0] device_elapsed_cycle_count_d;

  // 每经过一个下游设备周期，就累加一次频率比例。
  // 这样不需要动态乘法器。
  reg  [63:0] calibrated_elapsed_cycle_scaled_q;
  reg  [63:0] calibrated_elapsed_cycle_scaled_d;

  // 保存定点数计算中未达到一个完整CPU周期的部分。
  // 该余数会带到下一笔事务，避免小数截断误差持续累积。
  reg  [63:0] frequency_ratio_fraction_remainder_q;
  reg  [63:0] frequency_ratio_fraction_remainder_d;

  // 下游已经完成，但上游还需要继续等待的周期数。
  reg  [31:0] response_delay_cycle_count_q;
  reg  [31:0] response_delay_cycle_count_d;

  // 下游响应只能接收一次。延迟期间必须保存响应内容。
  reg  [31:0] delayed_response_data_q;
  reg  [31:0] delayed_response_data_d;
  reg         delayed_response_error_q;
  reg         delayed_response_error_d;

  wire        apb_setup_phase_present;
  wire        downstream_response_occurred;
  wire        upstream_response_occurred;

  assign apb_setup_phase_present      = in_psel && !in_penable;

  assign downstream_response_occurred = out_psel && out_penable && out_pready;

  assign upstream_response_occurred   = in_psel && in_penable && in_pready;

  // 当前周期下游响应时，本次设备事务共经过多少周期。
  wire [31:0] current_device_elapsed_cycle_count;

  assign current_device_elapsed_cycle_count = device_elapsed_cycle_count_q + 32'd1;

  // 加上当前设备周期以及上一笔事务保留下来的小数部分。
  wire [63:0] current_calibrated_total_cycle_scaled;

  assign current_calibrated_total_cycle_scaled =
      calibrated_elapsed_cycle_scaled_q +
      FREQUENCY_RATIO_SCALED +
      frequency_ratio_fraction_remainder_q;

  wire [63:0] calibrated_total_cycle_count;

  assign calibrated_total_cycle_count =
      current_calibrated_total_cycle_scaled >>
      FREQUENCY_RATIO_SCALE_SHIFT;

  wire [63:0] next_frequency_ratio_fraction_remainder;

  assign next_frequency_ratio_fraction_remainder =
      current_calibrated_total_cycle_scaled -
      (calibrated_total_cycle_count <<
       FREQUENCY_RATIO_SCALE_SHIFT);

  // 下游设备已经消耗了k个周期，因此这里只继续补上：
  //
  // additional = calibrated_total - k
  wire [63:0] additional_response_delay_cycle_count;

  assign additional_response_delay_cycle_count =
      (calibrated_total_cycle_count >
       {32'b0, current_device_elapsed_cycle_count})
      ? calibrated_total_cycle_count -
        {32'b0, current_device_elapsed_cycle_count}
      : 64'b0;

`ifndef SYNTHESIS
  initial begin
    if (FREQUENCY_RATIO_SCALE_SHIFT <= 0) begin
      $fatal(1, "FREQUENCY_RATIO_SCALE_SHIFT must be greater than zero");
    end

    if (FREQUENCY_RATIO_SCALED < FREQUENCY_RATIO_SCALE) begin
      $fatal(1, "CPU/peripheral frequency ratio must be at least one");
    end
  end
`endif

  // --------------------------------------------------------------------------
  // 第一段：状态输出
  // --------------------------------------------------------------------------

  always @(*) begin
    out_paddr  = in_paddr;
    out_pprot  = in_pprot;
    out_pwrite = in_pwrite;
    out_pwdata = in_pwdata;
    out_pstrb  = in_pstrb;

    out_psel    = 1'b0;
    out_penable = 1'b0;

    in_pready  = 1'b0;
    in_prdata  = 32'b0;
    in_pslverr = 1'b0;

    case (apb_delay_state_q)
      APB_WAIT_REQUEST_STATE, APB_WAIT_DEVICE_RESPONSE_STATE: begin
        // 请求尚未被下游完成，因此正常转发APB请求。
        out_psel    = in_psel;
        out_penable = in_penable;

        in_prdata  = out_prdata;
        in_pslverr = out_pslverr;

        // 如果计算结果不需要额外延迟，可以在当前周期直接返回。
        if ((apb_delay_state_q ==
             APB_WAIT_DEVICE_RESPONSE_STATE) &&
            downstream_response_occurred &&
            (additional_response_delay_cycle_count == 64'd0)) begin
          in_pready = 1'b1;
        end
      end

      APB_DELAY_RESPONSE_STATE: begin
        // 下游设备已经响应，不能继续向下游保持PSEL/PENABLE，
        // 否则同一笔带副作用的读写可能被执行多次。
        out_psel    = 1'b0;
        out_penable = 1'b0;

        in_prdata  = delayed_response_data_q;
        in_pslverr = delayed_response_error_q;

        // count=1对应最后一个额外等待周期。
        if (response_delay_cycle_count_q == 32'd1) begin
          in_pready = 1'b1;
        end
      end

      default: begin
        out_psel    = 1'b0;
        out_penable = 1'b0;
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // 第二段：状态转移和寄存器下一值
  // --------------------------------------------------------------------------

  always @(*) begin
    apb_delay_state_d                    = apb_delay_state_q;
    device_elapsed_cycle_count_d         = device_elapsed_cycle_count_q;
    calibrated_elapsed_cycle_scaled_d    = calibrated_elapsed_cycle_scaled_q;
    frequency_ratio_fraction_remainder_d = frequency_ratio_fraction_remainder_q;
    response_delay_cycle_count_d         = response_delay_cycle_count_q;
    delayed_response_data_d              = delayed_response_data_q;
    delayed_response_error_d             = delayed_response_error_q;

    case (apb_delay_state_q)
      APB_WAIT_REQUEST_STATE: begin
        if (apb_setup_phase_present) begin
          apb_delay_state_d                 = APB_WAIT_DEVICE_RESPONSE_STATE;
          device_elapsed_cycle_count_d      = 32'd0;
          calibrated_elapsed_cycle_scaled_d = 64'd0;
          response_delay_cycle_count_d      = 32'd0;
        end
      end

      APB_WAIT_DEVICE_RESPONSE_STATE: begin
        if (downstream_response_occurred) begin
          frequency_ratio_fraction_remainder_d = next_frequency_ratio_fraction_remainder;

          if (additional_response_delay_cycle_count == 64'd0) begin
            // 无额外延迟，当前周期已经直接返回。
            apb_delay_state_d = APB_WAIT_REQUEST_STATE;
          end else begin
            // 截获设备响应，随后停止访问下游设备。
            delayed_response_data_d      = out_prdata;
            delayed_response_error_d     = out_pslverr;
            response_delay_cycle_count_d = additional_response_delay_cycle_count[31:0];
            apb_delay_state_d            = APB_DELAY_RESPONSE_STATE;
          end
        end else begin
          device_elapsed_cycle_count_d = device_elapsed_cycle_count_q + 32'd1;

          calibrated_elapsed_cycle_scaled_d =
              calibrated_elapsed_cycle_scaled_q +
              FREQUENCY_RATIO_SCALED;
        end
      end

      APB_DELAY_RESPONSE_STATE: begin
        if (response_delay_cycle_count_q > 32'd1) begin
          response_delay_cycle_count_d = response_delay_cycle_count_q - 32'd1;
        end else if (upstream_response_occurred) begin
          response_delay_cycle_count_d = 32'd0;
          apb_delay_state_d            = APB_WAIT_REQUEST_STATE;
        end
      end

      default: begin
        apb_delay_state_d = APB_WAIT_REQUEST_STATE;
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // 第三段：寄存器更新
  // --------------------------------------------------------------------------

  always @(posedge clock) begin
    if (reset) begin
      apb_delay_state_q <= APB_WAIT_REQUEST_STATE;
    end else begin
      apb_delay_state_q <= apb_delay_state_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      device_elapsed_cycle_count_q      <= 32'd0;
      calibrated_elapsed_cycle_scaled_q <= 64'd0;
    end else begin
      device_elapsed_cycle_count_q      <= device_elapsed_cycle_count_d;
      calibrated_elapsed_cycle_scaled_q <= calibrated_elapsed_cycle_scaled_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      frequency_ratio_fraction_remainder_q <= 64'd0;
      response_delay_cycle_count_q         <= 32'd0;
    end else begin
      frequency_ratio_fraction_remainder_q <= frequency_ratio_fraction_remainder_d;
      response_delay_cycle_count_q         <= response_delay_cycle_count_d;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      delayed_response_data_q  <= 32'd0;
      delayed_response_error_q <= 1'b0;
    end else begin
      delayed_response_data_q  <= delayed_response_data_d;
      delayed_response_error_q <= delayed_response_error_d;
    end
  end

endmodule
