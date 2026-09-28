module ps2_top_apb(
  input         clock,
  input         reset,
  input  [31:0] in_paddr,
  input         in_psel,
  input         in_penable,
  input  [2:0]  in_pprot,
  input         in_pwrite,
  input  [31:0] in_pwdata,
  input  [3:0]  in_pstrb,
  output        in_pready,
  output [31:0] in_prdata,
  output        in_pslverr,

  input         ps2_clk,
  input         ps2_data
);

  localparam [2:0] PS2_DATA_REGISTER_OFFSET = 3'h0;
  localparam [4:0] SCAN_CODE_FIFO_DEPTH      = 5'd16;

  wire       apb_access;
  wire [2:0] register_offset;
  wire       data_register_read_occurred;

  assign apb_access                  = in_psel && in_penable;
  assign register_offset             = in_paddr[2:0];
  assign data_register_read_occurred = apb_access && !in_pwrite &&
                                       (register_offset == PS2_DATA_REGISTER_OFFSET);

  assign in_pready  = 1'b1;
  assign in_pslverr = apb_access &&
                      (in_pwrite || (register_offset != PS2_DATA_REGISTER_OFFSET));

  // PS/2 clock and data are asynchronous to the SoC clock. Synchronize both
  // signals before detecting the PS/2 falling edge used for sampling.
  reg [2:0] ps2_clock_synchronize_q;
  reg [1:0] ps2_data_synchronize_q;

  always @(posedge clock) begin
    if (reset) begin
      ps2_clock_synchronize_q <= 3'b111;
      ps2_data_synchronize_q  <= 2'b11;
    end else begin
      ps2_clock_synchronize_q <= {ps2_clock_synchronize_q[1:0], ps2_clk};
      ps2_data_synchronize_q  <= {ps2_data_synchronize_q[0], ps2_data};
    end
  end

  wire ps2_clock_falling_edge;
  wire synchronized_ps2_data;

  assign ps2_clock_falling_edge = ps2_clock_synchronize_q[2] &&
                                  !ps2_clock_synchronize_q[1];
  assign synchronized_ps2_data = ps2_data_synchronize_q[1];

  // A PS/2 frame contains start, eight data bits, odd parity and stop.
  // Bits 0..9 are stored here; the stop bit is checked directly on bit 10.
  reg [9:0] received_frame_q;
  reg [3:0] received_bit_count_q;

  wire       complete_frame_received;
  wire       received_frame_valid;
  wire [7:0] received_scan_code;

  assign complete_frame_received = ps2_clock_falling_edge &&
                                   (received_bit_count_q == 4'd10);
  assign received_frame_valid    = (received_frame_q[0] == 1'b0) &&
                                   (synchronized_ps2_data == 1'b1) &&
                                   (^received_frame_q[9:1]);
  assign received_scan_code      = received_frame_q[8:1];

  always @(posedge clock) begin
    if (reset) begin
      received_frame_q     <= 10'b0;
      received_bit_count_q <= 4'b0;
    end else if (ps2_clock_falling_edge) begin
      if (received_bit_count_q == 4'd10) begin
        received_bit_count_q <= 4'b0;
      end else begin
        received_frame_q[received_bit_count_q] <= synchronized_ps2_data;
        received_bit_count_q                   <= received_bit_count_q + 4'd1;
      end
    end
  end

  // Keep raw Set-2 scan bytes in a FIFO. Prefix bytes such as E0 and F0 must
  // remain ordered so software can reconstruct extended and release events.
  reg [7:0] scan_code_fifo_array [0:15];
  reg [3:0] fifo_read_index_q;
  reg [3:0] fifo_write_index_q;
  reg [4:0] fifo_entry_count_q;

  wire scan_code_fifo_read_occurred;
  wire scan_code_fifo_write_occurred;

  assign scan_code_fifo_read_occurred = data_register_read_occurred &&
                                        (fifo_entry_count_q != 5'd0);
  assign scan_code_fifo_write_occurred = complete_frame_received &&
                                         received_frame_valid &&
                                         ((fifo_entry_count_q < SCAN_CODE_FIFO_DEPTH) ||
                                          scan_code_fifo_read_occurred);

  always @(posedge clock) begin
    if (reset) begin
      fifo_read_index_q  <= 4'b0;
      fifo_write_index_q <= 4'b0;
      fifo_entry_count_q <= 5'b0;
    end else begin
      if (scan_code_fifo_write_occurred) begin
        scan_code_fifo_array[fifo_write_index_q] <= received_scan_code;
        fifo_write_index_q                       <= fifo_write_index_q + 4'd1;
      end

      if (scan_code_fifo_read_occurred) begin
        fifo_read_index_q <= fifo_read_index_q + 4'd1;
      end

      case ({scan_code_fifo_write_occurred, scan_code_fifo_read_occurred})
        2'b10: fifo_entry_count_q <= fifo_entry_count_q + 5'd1;
        2'b01: fifo_entry_count_q <= fifo_entry_count_q - 5'd1;
        default: ;
      endcase
    end
  end

  assign in_prdata = (fifo_entry_count_q != 5'd0)
                   ? {24'b0, scan_code_fifo_array[fifo_read_index_q]}
                   : 32'b0;

endmodule
