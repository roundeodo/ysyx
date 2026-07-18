// Simulation-only AXI4-Lite UART slave.
//
// A completed write to UART_TX_ADDR prints WDATA[7:0] when WSTRB[0] is set.
// This module intentionally models only the bus-visible behavior needed by the
// current NPC environment; it is not a synthesizable UART transmitter.
//
// Do not add this file to filelist.f until every functional TODO is complete.
module riscv32_axi_lite_uart_sim
  import riscv32_pkg::*;
#(
    parameter logic [XLEN-1:0] UART_BASE_ADDR     = 32'h1000_0000,
    parameter logic [XLEN-1:0] UART_TX_REG_OFFSET = 32'h0000_0000
) (
    input logic clk_i,
    input logic rst_ni,

    // AXI4-Lite slave interface from the address router.
    input  axi_lite_addr_t uart_axi_ar_i,
    input  logic           uart_axi_arvalid_i,
    output logic           uart_axi_arready_o,
    output axi_lite_r_t    uart_axi_r_o,
    output logic           uart_axi_rvalid_o,
    input  logic           uart_axi_rready_i,

    input  axi_lite_addr_t uart_axi_aw_i,
    input  logic           uart_axi_awvalid_i,
    output logic           uart_axi_awready_o,
    input  axi_lite_w_t    uart_axi_w_i,
    input  logic           uart_axi_wvalid_i,
    output logic           uart_axi_wready_o,
    output axi_lite_b_t    uart_axi_b_o,
    output logic           uart_axi_bvalid_o,
    input  logic           uart_axi_bready_i
);

  localparam logic [XLEN-1:0] UART_TX_ADDR =
      UART_BASE_ADDR + UART_TX_REG_OFFSET;

  typedef enum logic {
    READ_ACCEPT_AR,
    READ_RETURN_R
  } read_state_e;

  typedef enum logic {
    WRITE_COLLECT_AW_W,
    WRITE_RETURN_B
  } write_state_e;

  read_state_e  read_state_q;
  read_state_e  read_state_d;
  write_state_e write_state_q;
  write_state_e write_state_d;

  axi_lite_r_t read_response_q;
  axi_lite_r_t read_response_d;
  axi_lite_b_t write_response_q;
  axi_lite_b_t write_response_d;

  // AW and W are independent channels. These buffers allow either channel to
  // arrive first without assuming simultaneous VALID or READY.
  axi_lite_addr_t buffered_write_addr_q;
  axi_lite_addr_t buffered_write_addr_d;
  axi_lite_w_t    buffered_write_data_q;
  axi_lite_w_t    buffered_write_data_d;
  logic           write_addr_buffer_valid_q;
  logic           write_addr_buffer_valid_d;
  logic           write_data_buffer_valid_q;
  logic           write_data_buffer_valid_d;

  // These values represent the complete transaction visible in the current
  // cycle. A channel that handshakes now takes precedence over its old buffer.
  axi_lite_addr_t completed_write_addr;
  axi_lite_w_t    completed_write_data;
  logic           write_request_complete;
  logic           uart_tx_write_event;

  logic uart_ar_handshake;
  logic uart_r_handshake;
  logic uart_aw_handshake;
  logic uart_w_handshake;
  logic uart_b_handshake;

  assign uart_ar_handshake = uart_axi_arvalid_i && uart_axi_arready_o;
  assign uart_r_handshake  = uart_axi_rvalid_o && uart_axi_rready_i;
  assign uart_aw_handshake = uart_axi_awvalid_i && uart_axi_awready_o;
  assign uart_w_handshake  = uart_axi_wvalid_i && uart_axi_wready_o;
  assign uart_b_handshake  = uart_axi_bvalid_o && uart_axi_bready_i;

  always_comb begin
    completed_write_addr = uart_aw_handshake ?
                           uart_axi_aw_i : buffered_write_addr_q;
    completed_write_data = uart_w_handshake ?
                           uart_axi_w_i : buffered_write_data_q;

    write_request_complete =
        (write_addr_buffer_valid_q || uart_aw_handshake) &&
        (write_data_buffer_valid_q || uart_w_handshake);
  end

  // TODO(UART-1-READ-OUTPUT): Complete the two read-state branches directly
  // below.
  //
  // READ_ACCEPT_AR:
  // - Keep ARREADY high so one address can be accepted when no response is
  //   outstanding.
  // - Do not make ARREADY depend on ARVALID.
  //
  // READ_RETURN_R:
  // - Drive the registered read_response_q and assert RVALID.
  // - Hold both unchanged until uart_r_handshake.
  //
  // The baseline UART has no RTL receive path. A read of UART_TX_ADDR may return
  // data='0 with RRESP=OKAY. Other offsets reached inside the UART region should
  // return SLVERR: the xbar decoded the device successfully, but the UART does
  // not implement that register. Unmapped device regions are DECERR in the xbar.
  always_comb begin
    uart_axi_arready_o = 1'b0;
    uart_axi_r_o       = read_response_q;
    uart_axi_rvalid_o  = 1'b0;

    unique case (read_state_q)
      READ_ACCEPT_AR: begin
        // Drive ARREADY here.
      end

      READ_RETURN_R: begin
        // Drive the held R response here.
      end

      default: ;
    endcase
  end

  // TODO(UART-2-READ-NEXT): Complete the read next-state block directly below.
  //
  // On uart_ar_handshake:
  // - Set read_response_d.data='0.
  // - Set RRESP=OKAY when uart_axi_ar_i.addr == UART_TX_ADDR.
  // - Otherwise set RRESP=SLVERR.
  // - Enter READ_RETURN_R.
  //
  // On uart_r_handshake, return to READ_ACCEPT_AR. State movement must use the
  // full valid&&ready handshake, not either signal alone.
  always_comb begin
    read_state_d    = read_state_q;
    read_response_d = read_response_q;
  end

  // TODO(UART-3-WRITE-OUTPUT): Complete the two write-state branches directly
  // below.
  //
  // WRITE_COLLECT_AW_W:
  // - AWREADY = !write_addr_buffer_valid_q.
  // - WREADY  = !write_data_buffer_valid_q.
  // This permits AW-before-W, W-before-AW, and simultaneous AW/W.
  //
  // WRITE_RETURN_B:
  // - Drive write_response_q and assert BVALID.
  // - Hold BRESP and BVALID until uart_b_handshake.
  always_comb begin
    uart_axi_awready_o = 1'b0;
    uart_axi_wready_o  = 1'b0;
    uart_axi_b_o       = write_response_q;
    uart_axi_bvalid_o  = 1'b0;

    unique case (write_state_q)
      WRITE_COLLECT_AW_W: begin
        // Drive independent AWREADY and WREADY here.
      end

      WRITE_RETURN_B: begin
        // Drive the held B response here.
      end

      default: ;
    endcase
  end

  // TODO(UART-4-WRITE-NEXT): Complete the write next-state block directly
  // below. Keep every q/d hold default at the top.
  //
  // In WRITE_COLLECT_AW_W:
  // 1. On uart_aw_handshake, capture uart_axi_aw_i and set the AW buffer valid.
  // 2. On uart_w_handshake, capture uart_axi_w_i and set the W buffer valid.
  // 3. Test write_request_complete, which includes handshakes from the current
  //    cycle. Do not test only q flags or simultaneous AWVALID&&WVALID.
  // 4. If completed_write_addr.addr == UART_TX_ADDR:
  //    - set BRESP=AXI_RESP_OKAY;
  //    - pulse uart_tx_write_event only when completed_write_data.strb[0] is 1.
  //      An all-zero WSTRB is a legal no-op and still receives OKAY.
  // 5. For an unsupported UART register address, set BRESP=AXI_RESP_SLVERR and
  //    do not pulse uart_tx_write_event.
  // 6. Enter WRITE_RETURN_B after forming the response.
  //
  // In WRITE_RETURN_B, wait for uart_b_handshake, then clear both buffered-valid
  // flags and return to WRITE_COLLECT_AW_W. Do not clear them merely because
  // BVALID is asserted.
  always_comb begin
    write_state_d                = write_state_q;
    write_response_d             = write_response_q;
    buffered_write_addr_d        = buffered_write_addr_q;
    buffered_write_data_d        = buffered_write_data_q;
    write_addr_buffer_valid_d     = write_addr_buffer_valid_q;
    write_data_buffer_valid_d     = write_data_buffer_valid_q;
    uart_tx_write_event           = 1'b0;
  end

  // TODO(UART-5-PRINT): Put the simulation character output directly inside
  // the uart_tx_write_event branch below.
  //
  // Required operations:
  //   $write("%c", completed_write_data.data[7:0]);
  //   $fflush();
  //
  // This sequential event location guarantees at most one print per accepted
  // AXI write. Never place $write in WRITE_RETURN_B: BREADY may remain low for
  // many cycles and would print the same character repeatedly.
  always_ff @(posedge clk_i) begin
    if (uart_tx_write_event) begin
      // Print and flush one character here.
    end
  end

  // State, response, and write-buffer registers. This is the only block that
  // writes q signals.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q                 <= READ_ACCEPT_AR;
      read_response_q              <= '0;
      write_state_q                <= WRITE_COLLECT_AW_W;
      write_response_q             <= '0;
      buffered_write_addr_q        <= '0;
      buffered_write_data_q        <= '0;
      write_addr_buffer_valid_q     <= 1'b0;
      write_data_buffer_valid_q     <= 1'b0;
    end else begin
      read_state_q                 <= read_state_d;
      read_response_q              <= read_response_d;
      write_state_q                <= write_state_d;
      write_response_q             <= write_response_d;
      buffered_write_addr_q        <= buffered_write_addr_d;
      buffered_write_data_q        <= buffered_write_data_d;
      write_addr_buffer_valid_q     <= write_addr_buffer_valid_d;
      write_data_buffer_valid_q     <= write_data_buffer_valid_d;
    end
  end

  // TODO(UART-6-ASSERTIONS): Add these checks immediately below after the
  // functional TODOs pass directed tests:
  //
  // 1. RVALID && !RREADY |=> RVALID && $stable(R payload).
  // 2. BVALID && !BREADY |=> BVALID && $stable(BRESP).
  // 3. Once AW is buffered, AWREADY remains low until the write response is
  //    accepted; apply the equivalent check to W.
  // 4. uart_tx_write_event implies a complete AW+W transaction, TX address,
  //    WSTRB[0], and WRITE_COLLECT_AW_W state.
  // 5. uart_tx_write_event is a one-cycle pulse and cannot occur while BVALID is
  //    waiting for BREADY.
  // 6. RVALID and BVALID are low during reset.
  //
  // Directed tests must cover AW-before-W, W-before-AW, simultaneous AW/W,
  // stalled BREADY, stalled RREADY, WSTRB[0]=0, unsupported register offsets,
  // and consecutive characters.

  // NOTE(UART-RX): The previous C++ pmem path provided nonblocking terminal
  // input at 0x1000_0000. This baseline RTL-facing model implements only the
  // output behavior required by the current exercise. Add a separately named
  // simulation RX adapter later instead of hiding another DPI call in this
  // write-only checkpoint.

endmodule
