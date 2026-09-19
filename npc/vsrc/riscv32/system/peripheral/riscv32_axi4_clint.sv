// 单 hart 定时器：64 位 mtime/mtimecmp，32 位 AXI 访问，同步电平中断。
// 不支持的访问返回 SLVERR；读写响应在反压期间保持稳定。
module riscv32_axi4_clint
  import riscv32_axi4_pkg::*;
  import riscv32_addr_map_pkg::*;
#(
    parameter int unsigned CLINT_CLOCK_FREQ_HZ = 100_000_000,
    parameter int unsigned MTIME_INCREMENT_FREQ_HZ = 1_000_000
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  axi4_manager_to_target_t axi_target_i,
    output axi4_target_to_manager_t axi_target_o,
    output logic                    timer_interrupt_o
);

  localparam int unsigned CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT =
      CLINT_CLOCK_FREQ_HZ / MTIME_INCREMENT_FREQ_HZ;
  localparam int unsigned CLINT_CLOCK_CYCLE_COUNT_WIDTH =
      (CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT <= 1) ?
      1 : $clog2(CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT);

  logic [63:0] mtimecmp_q;
  logic [63:0] mtime_q;
  logic        register_write_valid;
  typedef enum logic [1:0] {
    MTIME_LOW_REGISTER,
    MTIME_HIGH_REGISTER,
    MTIMECMP_LOW_REGISTER,
    MTIMECMP_HIGH_REGISTER
  } clint_register_e;
  clint_register_e write_register_index_q;
  clint_register_e write_register_index_d;
  clint_register_e active_write_register;
  clint_register_e request_write_register;
  logic request_write_supported;

  assign timer_interrupt_o = (mtime_q >= mtimecmp_q);

  // MTIME 与比较值共用字节写使能规则。一次 32 位写不改变另一个半字。
  function automatic logic [31:0] merge_write_bytes(
      input logic [31:0] old_data, input logic [31:0] write_data, input logic [3:0] byte_strobe);
    logic [31:0] merged_data;
    merged_data = old_data;
    for (int unsigned byte_index = 0; byte_index < 4; byte_index++) begin
      if (byte_strobe[byte_index])
        merged_data[byte_index*8+:8] = write_data[byte_index*8+:8];
    end
    return merged_data;
  endfunction

  logic [63:0]                              mtime_d;
  logic [CLINT_CLOCK_CYCLE_COUNT_WIDTH-1:0] clint_clock_cycle_count_q;
  logic [CLINT_CLOCK_CYCLE_COUNT_WIDTH-1:0] clint_clock_cycle_count_d;

  always_comb begin
    mtime_d                   = mtime_q;
    clint_clock_cycle_count_d = clint_clock_cycle_count_q;

    if (CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT == 1) begin
      mtime_d                   = mtime_q + 64'd1;
      clint_clock_cycle_count_d = '0;
    end else if (clint_clock_cycle_count_q ==
                 CLINT_CLOCK_CYCLE_COUNT_WIDTH'(
                     CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT - 1
                 )) begin
      mtime_d                   = mtime_q + 64'd1;
      clint_clock_cycle_count_d = '0;
    end else begin
      clint_clock_cycle_count_d = clint_clock_cycle_count_q + 1'b1;
    end
    // 软件写优先于自动计数；零 WSTRB 不阻止计时。
    if (register_write_valid && (|axi_target_i.w.strb)) begin
      case (active_write_register)
        MTIME_LOW_REGISTER:
          mtime_d = {
          mtime_q[63:32], merge_write_bytes(mtime_q[31:0], axi_target_i.w.data, axi_target_i.w.strb)
        };
        MTIME_HIGH_REGISTER:
          mtime_d = {
          merge_write_bytes(mtime_q[63:32], axi_target_i.w.data, axi_target_i.w.strb), mtime_q[31:0]
        };
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q                   <= '0;
      clint_clock_cycle_count_q <= '0;
    end else begin
      mtime_q                   <= mtime_d;
      clint_clock_cycle_count_q <= clint_clock_cycle_count_d;
    end
  end

  // 比较值只接受软件字节写；复位为全 1，避免上电立即触发中断。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtimecmp_q <= '1;
    end else if (register_write_valid) begin
      case (active_write_register)
        MTIMECMP_LOW_REGISTER:
          mtimecmp_q[31:0] <= merge_write_bytes(
            mtimecmp_q[31:0], axi_target_i.w.data, axi_target_i.w.strb
        );
        MTIMECMP_HIGH_REGISTER:
          mtimecmp_q[63:32] <= merge_write_bytes(
            mtimecmp_q[63:32], axi_target_i.w.data, axi_target_i.w.strb
        );
        default: ;
      endcase
    end
  end

  typedef enum logic {
    READ_ACCEPT_ADDRESS,
    READ_RETURN_DATA
  } read_state_e;

  read_state_e read_state_q;
  read_state_e read_state_d;

  axi4_read_data_t read_response_q;
  axi4_read_data_t read_response_d;
  logic [7:0]      read_burst_length_q;
  logic [7:0]      read_burst_length_d;
  logic [7:0]      read_beat_index_q;
  logic [7:0]      read_beat_index_d;

  logic [63:0] mtime_read_snapshot_q;
  logic [63:0] mtime_read_snapshot_d;
  logic        mtime_read_snapshot_present_q;
  logic        mtime_read_snapshot_present_d;

  logic read_address_handshake;
  logic read_data_handshake;

  assign read_address_handshake = axi_target_i.ar_valid && axi_target_o.ar_ready;
  assign read_data_handshake    = axi_target_o.r_valid && axi_target_i.r_ready;

  typedef enum logic [1:0] {
    WRITE_ACCEPT_ADDRESS,
    WRITE_RECEIVE_DATA,
    WRITE_RETURN_RESPONSE
  } write_state_e;

  write_state_e         write_state_q;
  write_state_e         write_state_d;
  axi4_write_response_t write_response_q;
  axi4_write_response_t write_response_d;

  logic       write_request_supported_q;
  logic       write_request_supported_d;
  logic [7:0] write_beats_remaining_q;
  logic [7:0] write_beats_remaining_d;

  logic write_address_handshake;
  logic write_data_handshake;
  logic write_response_handshake;

  assign write_address_handshake  = axi_target_i.aw_valid && axi_target_o.aw_ready;
  assign write_data_handshake     = axi_target_i.w_valid && axi_target_o.w_ready;
  assign write_response_handshake = axi_target_o.b_valid && axi_target_i.b_ready;

  // AW 和 W 分别握手。只有合法的单拍写能更新寄存器；非法 burst 消耗全部
  // LEN+1 拍后返回一次 SLVERR，不因第一拍的地址碰巧合法而部分修改寄存器。
  always_comb begin
    axi_target_o.ar_ready = (read_state_q == READ_ACCEPT_ADDRESS) ||
        (read_state_q == READ_RETURN_DATA && axi_target_i.r_ready && read_response_q.last);
    axi_target_o.r        = read_response_q;
    axi_target_o.r_valid  = (read_state_q == READ_RETURN_DATA);
    axi_target_o.aw_ready = (write_state_q == WRITE_ACCEPT_ADDRESS) ||
        (write_state_q == WRITE_RETURN_RESPONSE && axi_target_i.b_ready);
    axi_target_o.w_ready  = (write_state_q == WRITE_RECEIVE_DATA) ||
        (axi_target_o.aw_ready && axi_target_i.aw_valid);
    axi_target_o.b        = write_response_q;
    axi_target_o.b_valid  = (write_state_q == WRITE_RETURN_RESPONSE);
  end

  always_comb begin
    read_state_d                  = read_state_q;
    read_response_d               = read_response_q;
    read_burst_length_d           = read_burst_length_q;
    read_beat_index_d             = read_beat_index_q;
    mtime_read_snapshot_d         = mtime_read_snapshot_q;
    mtime_read_snapshot_present_d = mtime_read_snapshot_present_q;

    unique case (read_state_q)
      READ_ACCEPT_ADDRESS: ;

      READ_RETURN_DATA: begin
        if (read_data_handshake) begin
          if (read_beat_index_q == read_burst_length_q) begin
            read_state_d = READ_ACCEPT_ADDRESS;
          end else begin
            read_beat_index_d    = read_beat_index_q + 1'b1;
            read_response_d.data = '0;
            read_response_d.resp = AXI4_RESP_SLVERR;
            read_response_d.last = (read_beat_index_q + 1'b1 == read_burst_length_q);
          end
        end
      end

      default: read_state_d = READ_ACCEPT_ADDRESS;
    endcase

    // 新地址握手覆盖已完成的旧事务；旧响应仍由 q 输出。
    if (read_address_handshake) begin
      read_burst_length_d  = axi_target_i.ar.len;
      read_beat_index_d    = '0;
      read_response_d      = '0;
      read_response_d.id   = axi_target_i.ar.id;
      read_response_d.resp = AXI4_RESP_SLVERR;
      read_response_d.last = (axi_target_i.ar.len == 0);

      // 普通寄存器访问为单拍 32 位；非法 burst 仍返回 LEN+1 个错误 beat。
      // 64 位配置另支持整宽 mtime 读取，不改变当前 RV32 访问规则。
      if ((MEM_AXI_DATA_WIDTH == 64) && (axi_target_i.ar.len == 0) &&
          (axi_target_i.ar.size == 3'd3) &&
          (axi_target_i.ar.addr == CLINT_MTIME_LOW_ADDR)) begin
        read_response_d.data          = axi4_data_t'(mtime_q);
        read_response_d.resp          = AXI4_RESP_OKAY;
        mtime_read_snapshot_present_d = 1'b0;
      end else if ((axi_target_i.ar.len == 0) &&
          (axi_target_i.ar.size == 3'd2) &&
          (axi_target_i.ar.burst inside {AXI4_BURST_FIXED, AXI4_BURST_INCR})) begin
        unique case (axi_target_i.ar.addr)
          CLINT_MTIME_LOW_ADDR: begin
            mtime_read_snapshot_d         = mtime_q;
            mtime_read_snapshot_present_d = 1'b1;
            read_response_d.data          = mtime_q[31:0];
            read_response_d.resp          = AXI4_RESP_OKAY;
          end

          CLINT_MTIME_HIGH_ADDR: begin
            read_response_d.data = mtime_read_snapshot_present_q ?
                mtime_read_snapshot_q[63:32] : mtime_q[63:32];
            mtime_read_snapshot_present_d = 1'b0;
            read_response_d.resp          = AXI4_RESP_OKAY;
          end

          CLINT_MTIMECMP_LOW_ADDR: begin
            read_response_d.data = mtimecmp_q[31:0];
            read_response_d.resp = AXI4_RESP_OKAY;
          end

          CLINT_MTIMECMP_HIGH_ADDR: begin
            read_response_d.data = mtimecmp_q[63:32];
            read_response_d.resp = AXI4_RESP_OKAY;
          end

          default: ;
        endcase
      end

      read_state_d = READ_RETURN_DATA;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q                  <= READ_ACCEPT_ADDRESS;
      read_response_q               <= '0;
      read_burst_length_q           <= '0;
      read_beat_index_q             <= '0;
      mtime_read_snapshot_q         <= '0;
      mtime_read_snapshot_present_q <= 1'b0;
    end else begin
      read_state_q                  <= read_state_d;
      read_response_q               <= read_response_d;
      read_burst_length_q           <= read_burst_length_d;
      read_beat_index_q             <= read_beat_index_d;
      mtime_read_snapshot_q         <= mtime_read_snapshot_d;
      mtime_read_snapshot_present_q <= mtime_read_snapshot_present_d;
    end
  end

  // AW/W 同拍到达时直接使用当前地址；分开到达时使用已保存的寄存器选择。
  always_comb begin
    request_write_register = MTIME_LOW_REGISTER;
    request_write_supported = (axi_target_i.aw.len == 0) &&
        (axi_target_i.aw.size == 3'd2) &&
        (axi_target_i.aw.burst inside {AXI4_BURST_FIXED, AXI4_BURST_INCR});
    unique case (axi_target_i.aw.addr)
      CLINT_MTIME_LOW_ADDR:     request_write_register = MTIME_LOW_REGISTER;
      CLINT_MTIME_HIGH_ADDR:    request_write_register = MTIME_HIGH_REGISTER;
      CLINT_MTIMECMP_LOW_ADDR:  request_write_register = MTIMECMP_LOW_REGISTER;
      CLINT_MTIMECMP_HIGH_ADDR: request_write_register = MTIMECMP_HIGH_REGISTER;
      default: request_write_supported = 1'b0;
    endcase
  end
  assign active_write_register = (write_state_q == WRITE_RECEIVE_DATA) ?
      write_register_index_q : request_write_register;

  always_comb begin
    write_state_d             = write_state_q;
    write_response_d          = write_response_q;
    write_register_index_d    = write_register_index_q;
    write_request_supported_d = write_request_supported_q;
    write_beats_remaining_d   = write_beats_remaining_q;

    unique case (write_state_q)
      WRITE_ACCEPT_ADDRESS: ;

      WRITE_RECEIVE_DATA: begin
        if (write_data_handshake) begin
          if (write_beats_remaining_q == 0) begin
            write_state_d = WRITE_RETURN_RESPONSE;
            if (write_request_supported_q && axi_target_i.w.last)
              write_response_d.resp = AXI4_RESP_OKAY;
          end else begin
            write_beats_remaining_d = write_beats_remaining_q - 1'b1;
          end
        end
      end

      WRITE_RETURN_RESPONSE: begin
        if (write_response_handshake) begin
          write_state_d = WRITE_ACCEPT_ADDRESS;
        end
      end

      default: write_state_d = WRITE_ACCEPT_ADDRESS;
    endcase

    // 新地址握手覆盖已完成的旧事务；旧响应仍由 q 输出。
    if (write_address_handshake) begin
      write_response_d.id       = axi_target_i.aw.id;
      write_response_d.resp     = AXI4_RESP_SLVERR;
      write_state_d             = WRITE_RECEIVE_DATA;
      write_beats_remaining_d   = axi_target_i.aw.len;
      write_request_supported_d = request_write_supported;
      write_register_index_d = request_write_register;
      if (write_data_handshake) begin
        if (axi_target_i.aw.len == 0) begin
          write_state_d = WRITE_RETURN_RESPONSE;
          if (request_write_supported && axi_target_i.w.last)
            write_response_d.resp = AXI4_RESP_OKAY;
        end else begin
          write_beats_remaining_d = axi_target_i.aw.len - 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_state_q             <= WRITE_ACCEPT_ADDRESS;
      write_response_q          <= '0;
      write_register_index_q    <= MTIME_LOW_REGISTER;
      write_request_supported_q <= 1'b0;
      write_beats_remaining_q   <= '0;
    end else begin
      write_state_q             <= write_state_d;
      write_response_q          <= write_response_d;
      write_register_index_q    <= write_register_index_d;
      write_request_supported_q <= write_request_supported_d;
      write_beats_remaining_q   <= write_beats_remaining_d;
    end
  end

  assign register_write_valid = write_data_handshake && axi_target_i.w.last &&
      ((write_state_q == WRITE_RECEIVE_DATA) ?
       write_request_supported_q : request_write_supported);

`ifndef SYNTHESIS
  initial begin
    assert (MTIME_INCREMENT_FREQ_HZ > 0 &&
            CLINT_CLOCK_FREQ_HZ >= MTIME_INCREMENT_FREQ_HZ &&
            CLINT_CLOCK_FREQ_HZ % MTIME_INCREMENT_FREQ_HZ == 0)
    else
      $fatal(1, "CLINT requires an integer, nonzero clock divider");
  end
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    axi_target_o.r_valid && !axi_target_i.r_ready |=>
      axi_target_o.r_valid && $stable(axi_target_o.r));
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    axi_target_o.b_valid && !axi_target_i.b_ready |=>
      axi_target_o.b_valid && $stable(axi_target_o.b));
`endif
endmodule : riscv32_axi4_clint
