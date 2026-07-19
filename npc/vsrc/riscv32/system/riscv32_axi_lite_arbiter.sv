// Two-to-one AXI4-Lite arbiter for the current NPC memory system.
// IFU is a read-only master; LSU is a read/write master. The requester of each
// accepted read is retained from the AR handshake through the matching R handshake.
module riscv32_axi_lite_arbiter
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // IFU read-only master side
    input  axi_lite_addr_t ifu_axi_ar_i,
    input  logic           ifu_axi_arvalid_i,
    output logic           ifu_axi_arready_o,
    output axi_lite_r_t    ifu_axi_r_o,
    output logic           ifu_axi_rvalid_o,
    input  logic           ifu_axi_rready_i,

    // LSU read/write master side
    input  axi_lite_addr_t lsu_axi_ar_i,
    input  logic           lsu_axi_arvalid_i,
    output logic           lsu_axi_arready_o,
    output axi_lite_r_t    lsu_axi_r_o,
    output logic           lsu_axi_rvalid_o,
    input  logic           lsu_axi_rready_i,

    input  axi_lite_addr_t lsu_axi_aw_i,
    input  logic           lsu_axi_awvalid_i,
    output logic           lsu_axi_awready_o,
    input  axi_lite_w_t    lsu_axi_w_i,
    input  logic           lsu_axi_wvalid_i,
    output logic           lsu_axi_wready_o,
    output axi_lite_b_t    lsu_axi_b_o,
    output logic           lsu_axi_bvalid_o,
    input  logic           lsu_axi_bready_i,

    // Single AXI4-Lite memory slave side
    output axi_lite_addr_t mem_axi_ar_o,
    output logic           mem_axi_arvalid_o,
    input  logic           mem_axi_arready_i,
    input  axi_lite_r_t    mem_axi_r_i,
    input  logic           mem_axi_rvalid_i,
    output logic           mem_axi_rready_o,

    output axi_lite_addr_t mem_axi_aw_o,
    output logic           mem_axi_awvalid_o,
    input  logic           mem_axi_awready_i,
    output axi_lite_w_t    mem_axi_w_o,
    output logic           mem_axi_wvalid_o,
    input  logic           mem_axi_wready_i,
    input  axi_lite_b_t    mem_axi_b_i,
    input  logic           mem_axi_bvalid_i,
    output logic           mem_axi_bready_o
);

  // READ_ARBITRATE provides a zero-extra-cycle AR fast path. If memory stalls that
  // path, the requester is registered and READ_SEND_ADDRESS retains the route until
  // the AR handshake completes. AXI requires the selected master to retain ARVALID
  // and its payload while ARREADY is low.
  typedef enum logic [1:0] {
    READ_ARBITRATE,
    READ_SEND_ADDRESS,
    READ_WAIT_RESPONSE
  } read_state_e;

  typedef enum logic {
    READ_REQUESTER_IFU,
    READ_REQUESTER_LSU
  } read_requester_e;

  read_state_e     read_state_q;
  read_state_e     read_state_d;
  read_requester_e active_read_requester_q;
  read_requester_e active_read_requester_d;

  // last_served_requester_q records which requester completed the previous AR
  // handshake. When both masters request together, select the other requester to
  // implement transaction-level round-robin fairness. Update it only on AR handshake.
  read_requester_e last_served_requester_q;
  read_requester_e last_served_requester_d;

  // Combinational arbitration result. It is meaningful only when
  // selected_read_request_valid is high in READ_ARBITRATE.
  read_requester_e selected_read_requester;
  logic            selected_read_request_valid;

  logic            mem_ar_handshake;
  logic            mem_r_handshake;

  assign mem_ar_handshake = mem_axi_arvalid_o && mem_axi_arready_i;
  assign mem_r_handshake  = mem_axi_rvalid_i && mem_axi_rready_o;

  // Requester selection. This block does not depend on memory ready, so the AR fast
  // path cannot create a ready-to-valid combinational loop.
  always_comb begin
    selected_read_requester     = READ_REQUESTER_IFU;
    selected_read_request_valid = 1'b0;

    if (ifu_axi_arvalid_i && lsu_axi_arvalid_i) begin
      selected_read_request_valid = 1'b1;
      selected_read_requester     =
        (last_served_requester_q == READ_REQUESTER_IFU)
          ? READ_REQUESTER_LSU : READ_REQUESTER_IFU;
    end else if (ifu_axi_arvalid_i) begin
      selected_read_request_valid = 1'b1;
      selected_read_requester     = READ_REQUESTER_IFU;
    end else if (lsu_axi_arvalid_i) begin
      selected_read_request_valid = 1'b1;
      selected_read_requester     = READ_REQUESTER_LSU;
    end
  end

  // Read-channel routing. Arbitration can forward AR immediately. After a stalled
  // fast-path attempt, active_read_requester_q keeps the selected route stable.
  always_comb begin
    ifu_axi_arready_o = 1'b0;
    ifu_axi_r_o       = '0;
    ifu_axi_rvalid_o  = 1'b0;

    lsu_axi_arready_o = 1'b0;
    lsu_axi_r_o       = '0;
    lsu_axi_rvalid_o  = 1'b0;

    mem_axi_ar_o      = '0;
    mem_axi_arvalid_o = 1'b0;
    mem_axi_rready_o  = 1'b0;

    unique case (read_state_q)
      READ_ARBITRATE: begin
        if (selected_read_request_valid) begin
          if (selected_read_requester == READ_REQUESTER_IFU) begin
            mem_axi_arvalid_o = ifu_axi_arvalid_i;
            ifu_axi_arready_o = mem_axi_arready_i;
            mem_axi_ar_o      = ifu_axi_ar_i;
          end else begin
            mem_axi_arvalid_o = lsu_axi_arvalid_i;
            lsu_axi_arready_o = mem_axi_arready_i;
            mem_axi_ar_o      = lsu_axi_ar_i;
          end
        end
      end

      READ_SEND_ADDRESS: begin
        if (active_read_requester_q == READ_REQUESTER_IFU) begin
          mem_axi_arvalid_o = ifu_axi_arvalid_i;
          ifu_axi_arready_o = mem_axi_arready_i;
          mem_axi_ar_o      = ifu_axi_ar_i;
        end else begin
          mem_axi_arvalid_o = lsu_axi_arvalid_i;
          lsu_axi_arready_o = mem_axi_arready_i;
          mem_axi_ar_o      = lsu_axi_ar_i;
        end
      end
      READ_WAIT_RESPONSE: begin
        if (active_read_requester_q == READ_REQUESTER_IFU) begin
          ifu_axi_rvalid_o = mem_axi_rvalid_i;
          mem_axi_rready_o = ifu_axi_rready_i;
          ifu_axi_r_o      = mem_axi_r_i;
        end else begin
          lsu_axi_rvalid_o = mem_axi_rvalid_i;
          mem_axi_rready_o = lsu_axi_rready_i;
          lsu_axi_r_o      = mem_axi_r_i;
        end
      end
      default: ;
    endcase
  end

  // The current IFU has no write channel, so LSU write traffic requires no
  // arbitration. Keep AW, W, and B as three independent direct connections.
  always_comb begin
    lsu_axi_awready_o = mem_axi_awready_i;
    lsu_axi_wready_o  = mem_axi_wready_i;
    lsu_axi_b_o       = mem_axi_b_i;
    lsu_axi_bvalid_o  = mem_axi_bvalid_i;

    mem_axi_aw_o      = lsu_axi_aw_i;
    mem_axi_awvalid_o = lsu_axi_awvalid_i;
    mem_axi_w_o       = lsu_axi_w_i;
    mem_axi_wvalid_o  = lsu_axi_wvalid_i;
    mem_axi_bready_o  = lsu_axi_bready_i;

    // AW与W是独立通道，不要增加“二者同时有效/同时ready”这样的附加条件。
  end

  // Read requester locking, address transfer, response transfer, and fairness state.
  always_comb begin
    read_state_d            = read_state_q;
    active_read_requester_d = active_read_requester_q;
    last_served_requester_d = last_served_requester_q;

    unique case (read_state_q)
      READ_ARBITRATE: begin
        if (selected_read_request_valid) begin
          // Lock the selected route in case the fast-path AR transfer stalls.
          active_read_requester_d = selected_read_requester;
          if (mem_ar_handshake) begin
            read_state_d            = READ_WAIT_RESPONSE;
            last_served_requester_d = selected_read_requester;
          end else begin
            read_state_d = READ_SEND_ADDRESS;
          end
        end
      end

      READ_SEND_ADDRESS: begin
        if (mem_ar_handshake) begin
          read_state_d            = READ_WAIT_RESPONSE;
          last_served_requester_d = active_read_requester_q;
        end
      end

      READ_WAIT_RESPONSE: begin
        if (mem_r_handshake) begin
          read_state_d = READ_ARBITRATE;
        end
      end

      default: begin
        read_state_d            = READ_ARBITRATE;
        active_read_requester_d = READ_REQUESTER_IFU;
        last_served_requester_d = READ_REQUESTER_IFU;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q            <= READ_ARBITRATE;
      active_read_requester_q <= READ_REQUESTER_IFU;
      last_served_requester_q <= READ_REQUESTER_IFU;
    end else begin
      read_state_q            <= read_state_d;
      active_read_requester_q <= active_read_requester_d;
      last_served_requester_q <= last_served_requester_d;
    end
  end

  p_only_one_read_requester_handshakes :
  assert property (
    @(posedge clk_i)
      !((ifu_axi_arvalid_i && ifu_axi_arready_o) &&
        (lsu_axi_arvalid_i && lsu_axi_arready_o))
  ) else $error("IFU and LSU AR handshakes occurred together");

  p_locked_read_requester_stable :
  assert property (
    @(posedge clk_i)
      (read_state_q inside {READ_SEND_ADDRESS, READ_WAIT_RESPONSE})
      |=> $stable(active_read_requester_q)
  ) else $error("Active read requester changed during an outstanding transaction");

  p_memory_ar_stable_while_stalled :
  assert property (
    @(posedge clk_i)
      mem_axi_arvalid_o && !mem_axi_arready_i
      |=> mem_axi_arvalid_o && $stable(mem_axi_ar_o)
  ) else $error("Memory AR channel changed while stalled");

  p_read_response_has_outstanding_request :
  assert property (
    @(posedge clk_i)
      mem_axi_rvalid_i |-> read_state_q == READ_WAIT_RESPONSE
  ) else $error("Memory returned R without an outstanding arbitrated read");

  p_read_response_has_single_destination :
  assert property (
    @(posedge clk_i)
      !(ifu_axi_rvalid_o && lsu_axi_rvalid_o)
  ) else $error("Memory R response was routed to both requesters");

  always_comb begin
    if (!rst_ni) begin
      p_reset_clears_output_valids :
      assert (!(mem_axi_arvalid_o || mem_axi_awvalid_o || mem_axi_wvalid_o ||
                ifu_axi_rvalid_o || lsu_axi_rvalid_o || lsu_axi_bvalid_o))
      else $error("AXI arbiter output VALID asserted during reset");
    end
  end

endmodule
