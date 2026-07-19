// Simulation-only AXI4-Lite UART slave.
//
// A completed write to UART_TX_ADDR prints WDATA[7:0] when WSTRB[0] is set.
// This module intentionally models only the bus-visible behavior needed by the
// current NPC environment; it is not a synthesizable UART transmitter.
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

  localparam logic [XLEN-1:0] UART_TX_ADDR = UART_BASE_ADDR + UART_TX_REG_OFFSET;

  typedef enum logic {
    READ_WAIT_AR,
    READ_RETURN_R
  } read_state_e;

  typedef enum logic {
    WRITE_WAIT_AW_W,
    WRITE_RETURN_B
  } write_state_e;

  read_state_e    read_state_q;
  read_state_e    read_state_d;
  write_state_e   write_state_q;
  write_state_e   write_state_d;

  axi_lite_r_t    read_response_q;
  axi_lite_r_t    read_response_d;
  axi_lite_b_t    write_response_q;
  axi_lite_b_t    write_response_d;

  // AW and W are independent channels. These buffers allow either channel to
  // arrive first without assuming simultaneous VALID or READY.
  axi_lite_addr_t buffered_write_addr_q;
  axi_lite_addr_t buffered_write_addr_d;
  axi_lite_w_t    buffered_write_data_q;
  axi_lite_w_t    buffered_write_data_d;
  logic           buffered_write_addr_present_q;
  logic           buffered_write_addr_present_d;
  logic           buffered_write_data_present_q;
  logic           buffered_write_data_present_d;

  // These payloads select newly accepted channel data when present; otherwise
  // they select data retained from an earlier independent channel handshake.
  axi_lite_addr_t write_addr_payload;
  axi_lite_w_t    write_data_payload;
  logic           write_request_payloads_present;
  logic           uart_tx_char_output_event;

  logic           uart_ar_handshake;
  logic           uart_r_handshake;
  logic           uart_aw_handshake;
  logic           uart_w_handshake;
  logic           uart_b_handshake;

  // This simulation UART does not implement AXI protection domains. Consume
  // both channel attributes explicitly so ignored protocol metadata is visible.
  /* verilator lint_off UNUSEDSIGNAL */
  logic           ignored_axi_prot_bits;
  /* verilator lint_on UNUSEDSIGNAL */

  assign uart_ar_handshake = uart_axi_arvalid_i && uart_axi_arready_o;
  assign uart_r_handshake  = uart_axi_rvalid_o && uart_axi_rready_i;
  assign uart_aw_handshake = uart_axi_awvalid_i && uart_axi_awready_o;
  assign uart_w_handshake  = uart_axi_wvalid_i && uart_axi_wready_o;
  assign uart_b_handshake  = uart_axi_bvalid_o && uart_axi_bready_i;
  assign ignored_axi_prot_bits = ^{uart_axi_ar_i.prot, write_addr_payload.prot};

  always_comb begin
    write_addr_payload = uart_aw_handshake ? uart_axi_aw_i : buffered_write_addr_q;
    write_data_payload = uart_w_handshake ? uart_axi_w_i : buffered_write_data_q;

    write_request_payloads_present =
        (buffered_write_addr_present_q || uart_aw_handshake) &&
        (buffered_write_data_present_q || uart_w_handshake);
  end

  // Only one read may be outstanding. The address channel is ready while no
  // response is pending; the registered response remains valid until its
  // handshake completes.
  // The baseline UART has no RTL receive path. A read of UART_TX_ADDR may return
  // data='0 with RRESP=OKAY. Other offsets reached inside the UART region should
  // return SLVERR: the xbar decoded the device successfully, but the UART does
  // not implement that register. Unmapped device regions are DECERR in the xbar.
  always_comb begin
    uart_axi_arready_o = 1'b0;
    uart_axi_r_o       = read_response_q;
    uart_axi_rvalid_o  = 1'b0;

    unique case (read_state_q)
      READ_WAIT_AR: begin
        uart_axi_arready_o = 1'b1;
      end

      READ_RETURN_R: begin
        uart_axi_rvalid_o = 1'b1;
      end

      default: ;
    endcase
  end

  always_comb begin
    read_state_d    = read_state_q;
    read_response_d = read_response_q;

    unique case (read_state_q)
      READ_WAIT_AR: begin
        if (uart_ar_handshake) begin
          read_response_d.data = '0;

          if (uart_axi_ar_i.addr == UART_TX_ADDR) read_response_d.resp = AXI_RESP_OKAY;
          else read_response_d.resp = AXI_RESP_SLVERR;

          read_state_d = READ_RETURN_R;
        end
      end

      READ_RETURN_R: begin
        if (uart_r_handshake) begin
          read_state_d = READ_WAIT_AR;
        end
      end
      default: ;
    endcase
  end

  always_comb begin
    uart_axi_awready_o = 1'b0;
    uart_axi_wready_o  = 1'b0;
    uart_axi_b_o       = write_response_q;
    uart_axi_bvalid_o  = 1'b0;

    unique case (write_state_q)
      WRITE_WAIT_AW_W: begin
        // Each independent channel remains ready while its local buffer is empty.
        uart_axi_awready_o = !buffered_write_addr_present_q;
        uart_axi_wready_o  = !buffered_write_data_present_q;
      end

      WRITE_RETURN_B: begin
        // The registered response remains valid until the master accepts it.
        uart_axi_bvalid_o = 1'b1;
      end

      default: ;
    endcase
  end

  always_comb begin
    write_state_d                 = write_state_q;
    write_response_d              = write_response_q;
    buffered_write_addr_d         = buffered_write_addr_q;
    buffered_write_data_d         = buffered_write_data_q;
    buffered_write_addr_present_d = buffered_write_addr_present_q;
    buffered_write_data_present_d = buffered_write_data_present_q;
    uart_tx_char_output_event     = 1'b0;

    unique case (write_state_q)
      WRITE_WAIT_AW_W: begin
        // Preserve independently accepted AW and W payloads. Separate if
        // statements allow both channels to handshake in the same cycle.
        if (uart_aw_handshake) begin
          buffered_write_addr_d         = uart_axi_aw_i;
          buffered_write_addr_present_d = 1'b1;
        end

        if (uart_w_handshake) begin
          buffered_write_data_d         = uart_axi_w_i;
          buffered_write_data_present_d = 1'b1;
        end

        // Current handshakes feed write_*_payload directly, providing the fast
        // path; an earlier unmatched channel is supplied by its local buffer.
        if (write_request_payloads_present) begin
          if (write_addr_payload.addr == UART_TX_ADDR) begin
            write_response_d.resp = AXI_RESP_OKAY;
            if (write_data_payload.strb[0]) begin
              uart_tx_char_output_event = 1'b1;
            end
          end else write_response_d.resp = AXI_RESP_SLVERR;
          write_state_d = WRITE_RETURN_B;
        end
      end

      WRITE_RETURN_B: begin
        // Release the buffered transaction only after the B handshake.
        if (uart_b_handshake) begin
          buffered_write_addr_present_d = 1'b0;
          buffered_write_data_present_d = 1'b0;
          write_state_d                 = WRITE_WAIT_AW_W;
        end
      end
      default: ;
    endcase
  end

  // Printing at the accepted write event guarantees one character per write,
  // independent of how long the B response is backpressured.
  always_ff @(posedge clk_i) begin
    if (uart_tx_char_output_event) begin
      $write("%c", write_data_payload.data[7:0]);
      $fflush();
    end
  end

  // State, response, and write-buffer registers. This is the only block that
  // writes q signals.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q                  <= READ_WAIT_AR;
      read_response_q               <= '0;
      write_state_q                 <= WRITE_WAIT_AW_W;
      write_response_q              <= '0;
      buffered_write_addr_q         <= '0;
      buffered_write_data_q         <= '0;
      buffered_write_addr_present_q <= 1'b0;
      buffered_write_data_present_q <= 1'b0;
    end else begin
      read_state_q                  <= read_state_d;
      read_response_q               <= read_response_d;
      write_state_q                 <= write_state_d;
      write_response_q              <= write_response_d;
      buffered_write_addr_q         <= buffered_write_addr_d;
      buffered_write_data_q         <= buffered_write_data_d;
      buffered_write_addr_present_q <= buffered_write_addr_present_d;
      buffered_write_data_present_q <= buffered_write_data_present_d;
    end
  end

  // TODO(UART-6-ASSERTIONS): Add these checks immediately below after the
  // functional TODOs pass directed tests:
  //
  // 1. RVALID && !RREADY |=> RVALID && $stable(R payload).
  // 2. BVALID && !BREADY |=> BVALID && $stable(BRESP).
  // 3. Once AW is buffered, AWREADY remains low until the write response is
  //    accepted; apply the equivalent check to W.
  // 4. uart_tx_char_output_event implies both AW and W payloads are present,
  //    the TX address is selected, WSTRB[0] is set, and the state is
  //    WRITE_WAIT_AW_W.
  // 5. uart_tx_char_output_event is a one-cycle pulse and cannot occur while
  //    BVALID is waiting for BREADY.
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
