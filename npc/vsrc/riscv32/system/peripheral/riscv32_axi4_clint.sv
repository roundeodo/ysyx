// Read-only CLINT mtime target. The AXI4 interface accepts one read and one
// write transaction at a time; unsupported writes complete with SLVERR.
module riscv32_axi4_clint
  import riscv32_axi4_pkg::*;
  import riscv32_addr_map_pkg::*;
#(
    parameter int unsigned CLINT_CLOCK_FREQ_HZ = 100_000_000,
    parameter int unsigned MTIME_INCREMENT_FREQ_HZ = 1_000_000
) (
    input logic clk_i,
    input logic rst_ni,

    input  axi4_manager_to_target_t axi_target_i,
    output axi4_target_to_manager_t axi_target_o
);

  // CLINT寄存器地址使用系统AXI地址宽度，寄存器偏移不建立局部宽度配置。

  localparam logic [MEM_AXI_ADDR_WIDTH-1:0] MTIME_LOW_ADDRESS =
      CLINT_BASE_ADDR + 32'h0000_0048;
  localparam logic [MEM_AXI_ADDR_WIDTH-1:0] MTIME_HIGH_ADDRESS =
      CLINT_BASE_ADDR + 32'h0000_004c;

  localparam int unsigned CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT =
      CLINT_CLOCK_FREQ_HZ / MTIME_INCREMENT_FREQ_HZ;
  localparam int unsigned CLINT_CLOCK_CYCLE_COUNT_WIDTH =
      (CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT <= 1) ?
      1 : $clog2(CLINT_CLOCK_CYCLES_PER_MTIME_INCREMENT);

  logic [63:0] mtime_q;
  logic [63:0] mtime_d;
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

  typedef enum logic {
    READ_ACCEPT_ADDRESS,
    READ_RETURN_DATA
  } read_state_e;

  read_state_e read_state_q;
  read_state_e read_state_d;

  axi4_read_data_t read_response_q;
  axi4_read_data_t read_response_d;
  logic [7:0] read_burst_length_q;
  logic [7:0] read_burst_length_d;
  logic [7:0] read_beat_index_q;
  logic [7:0] read_beat_index_d;

  logic [63:0] mtime_read_snapshot_q;
  logic [63:0] mtime_read_snapshot_d;
  logic        mtime_read_snapshot_present_q;
  logic        mtime_read_snapshot_present_d;

  logic read_address_handshake;
  logic read_data_handshake;

  assign read_address_handshake = axi_target_i.ar_valid && axi_target_o.ar_ready;
  assign read_data_handshake    = axi_target_o.r_valid && axi_target_i.r_ready;

  // Read output logic. The response register remains stable under R backpressure.
  always_comb begin
    axi_target_o.ar_ready = (read_state_q == READ_ACCEPT_ADDRESS);
    axi_target_o.r        = read_response_q;
    axi_target_o.r_valid  = (read_state_q == READ_RETURN_DATA);
  end

  always_comb begin
    read_state_d                        = read_state_q;
    read_response_d                     = read_response_q;
    read_burst_length_d                 = read_burst_length_q;
    read_beat_index_d                   = read_beat_index_q;
    mtime_read_snapshot_d               = mtime_read_snapshot_q;
    mtime_read_snapshot_present_d       = mtime_read_snapshot_present_q;

    unique case (read_state_q)
      READ_ACCEPT_ADDRESS: begin
        if (read_address_handshake) begin
          read_burst_length_d    = axi_target_i.ar.len;
          read_beat_index_d      = '0;
          read_response_d        = '0;
          read_response_d.id     = axi_target_i.ar.id;
          read_response_d.resp   = AXI4_RESP_SLVERR;
          read_response_d.last   = (axi_target_i.ar.len == 0);

          // CLINT registers are 32-bit, single-beat accesses. For an unsupported
          // burst the target still returns LEN+1 SLVERR beats, preserving AXI4.
          if ((axi_target_i.ar.len == 0) &&
              (axi_target_i.ar.size == 3'd2)) begin
            unique case (axi_target_i.ar.addr)
              MTIME_LOW_ADDRESS: begin
                mtime_read_snapshot_d         = mtime_q;
                mtime_read_snapshot_present_d = 1'b1;
                read_response_d.data          = mtime_q[31:0];
                read_response_d.resp          = AXI4_RESP_OKAY;
              end

              MTIME_HIGH_ADDRESS: begin
                read_response_d.data = mtime_read_snapshot_present_q ?
                    mtime_read_snapshot_q[63:32] : mtime_q[63:32];
                mtime_read_snapshot_present_d = 1'b0;
                read_response_d.resp          = AXI4_RESP_OKAY;
              end

              default: ;
            endcase
          end

          read_state_d = READ_RETURN_DATA;
        end
      end

      READ_RETURN_DATA: begin
        if (read_data_handshake) begin
          if (read_beat_index_q == read_burst_length_q) begin
            read_state_d = READ_ACCEPT_ADDRESS;
          end else begin
            read_beat_index_d     = read_beat_index_q + 1'b1;
            read_response_d.data  = '0;
            read_response_d.resp  = AXI4_RESP_SLVERR;
            read_response_d.last  = (read_beat_index_q + 1'b1 == read_burst_length_q);
          end
        end
      end

      default: read_state_d = READ_ACCEPT_ADDRESS;
    endcase
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

  typedef enum logic [1:0] {
    WRITE_ACCEPT_ADDRESS,
    WRITE_RECEIVE_DATA,
    WRITE_RETURN_RESPONSE
  } write_state_e;

  write_state_e write_state_q;
  write_state_e write_state_d;
  axi4_write_response_t write_response_q;
  axi4_write_response_t write_response_d;

  logic write_address_handshake;
  logic write_data_handshake;
  logic write_response_handshake;

  assign write_address_handshake = axi_target_i.aw_valid && axi_target_o.aw_ready;
  assign write_data_handshake = axi_target_i.w_valid && axi_target_o.w_ready;
  assign write_response_handshake = axi_target_o.b_valid && axi_target_i.b_ready;

  // mtime is read-only at this checkpoint. Consume every write beat and return
  // one SLVERR response carrying the AW transaction ID.
  always_comb begin
    axi_target_o.aw_ready = (write_state_q == WRITE_ACCEPT_ADDRESS);
    axi_target_o.w_ready  = (write_state_q == WRITE_RECEIVE_DATA);
    axi_target_o.b        = write_response_q;
    axi_target_o.b_valid  = (write_state_q == WRITE_RETURN_RESPONSE);
  end

  always_comb begin
    write_state_d    = write_state_q;
    write_response_d = write_response_q;

    unique case (write_state_q)
      WRITE_ACCEPT_ADDRESS: begin
        if (write_address_handshake) begin
          write_response_d.id   = axi_target_i.aw.id;
          write_response_d.resp = AXI4_RESP_SLVERR;
          write_state_d         = WRITE_RECEIVE_DATA;
        end
      end

      WRITE_RECEIVE_DATA: begin
        if (write_data_handshake && axi_target_i.w.last) begin
          write_state_d = WRITE_RETURN_RESPONSE;
        end
      end

      WRITE_RETURN_RESPONSE: begin
        if (write_response_handshake) begin
          write_state_d = WRITE_ACCEPT_ADDRESS;
        end
      end

      default: write_state_d = WRITE_ACCEPT_ADDRESS;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_state_q    <= WRITE_ACCEPT_ADDRESS;
      write_response_q <= '0;
    end else begin
      write_state_q    <= write_state_d;
      write_response_q <= write_response_d;
    end
  end

endmodule : riscv32_axi4_clint
