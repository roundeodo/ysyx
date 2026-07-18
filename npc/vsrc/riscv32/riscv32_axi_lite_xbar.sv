// Configurable one-to-N AXI4-Lite address router.
//
// This checkpoint receives the single AXI4-Lite stream produced by the NPC
// arbiter and routes each transaction to one address-mapped slave. Read and
// write routes are tracked independently. The module intentionally supports
// only one outstanding read and one outstanding write at this stage.
module riscv32_axi_lite_xbar
  import riscv32_pkg::*;
#(
    parameter int unsigned SLAVE_COUNT = 2,
    parameter logic [XLEN-1:0] SLAVE_BASE_ADDR[SLAVE_COUNT] = '{32'h1000_0000, 32'h8000_0000},
    parameter logic [XLEN-1:0] SLAVE_ADDR_MASK[SLAVE_COUNT] = '{32'hffff_f000, 32'hff00_0000}
) (
    input logic clk_i,
    input logic rst_ni,

    // AXI4-Lite input from the NPC arbiter.
    input  axi_lite_addr_t npc_axi_ar_i,
    input  logic           npc_axi_arvalid_i,
    output logic           npc_axi_arready_o,
    output axi_lite_r_t    npc_axi_r_o,
    output logic           npc_axi_rvalid_o,
    input  logic           npc_axi_rready_i,

    input  axi_lite_addr_t npc_axi_aw_i,
    input  logic           npc_axi_awvalid_i,
    output logic           npc_axi_awready_o,
    input  axi_lite_w_t    npc_axi_w_i,
    input  logic           npc_axi_wvalid_i,
    output logic           npc_axi_wready_o,
    output axi_lite_b_t    npc_axi_b_o,
    output logic           npc_axi_bvalid_o,
    input  logic           npc_axi_bready_i,

    // AXI4-Lite outputs to address-mapped slaves. Index i uses
    // SLAVE_BASE_ADDR[i] and SLAVE_ADDR_MASK[i].
    output axi_lite_addr_t slave_axi_ar_o     [SLAVE_COUNT],
    output logic           slave_axi_arvalid_o[SLAVE_COUNT],
    input  logic           slave_axi_arready_i[SLAVE_COUNT],
    input  axi_lite_r_t    slave_axi_r_i      [SLAVE_COUNT],
    input  logic           slave_axi_rvalid_i [SLAVE_COUNT],
    output logic           slave_axi_rready_o [SLAVE_COUNT],

    output axi_lite_addr_t slave_axi_aw_o     [SLAVE_COUNT],
    output logic           slave_axi_awvalid_o[SLAVE_COUNT],
    input  logic           slave_axi_awready_i[SLAVE_COUNT],
    output axi_lite_w_t    slave_axi_w_o      [SLAVE_COUNT],
    output logic           slave_axi_wvalid_o [SLAVE_COUNT],
    input  logic           slave_axi_wready_i [SLAVE_COUNT],
    input  axi_lite_b_t    slave_axi_b_i      [SLAVE_COUNT],
    input  logic           slave_axi_bvalid_i [SLAVE_COUNT],
    output logic           slave_axi_bready_o [SLAVE_COUNT]
);

  localparam int unsigned SLAVE_INDEX_WIDTH = (SLAVE_COUNT <= 1) ? 1 : $clog2(SLAVE_COUNT);

  typedef logic [SLAVE_INDEX_WIDTH-1:0] slave_index_t;

  typedef enum logic [1:0] {
    READ_ACCEPT_AR,
    READ_WAIT_R,
    READ_RETURN_DECERR
  } read_state_e;

  typedef enum logic [1:0] {
    WRITE_COLLECT_AW_W,
    WRITE_FORWARD_AW_W,
    WRITE_WAIT_B,
    WRITE_RETURN_DECERR
  } write_state_e;

  read_state_e                      read_state_q;
  read_state_e                      read_state_d;
  write_state_e                     write_state_q;
  write_state_e                     write_state_d;

  // The selected indexes are transaction route records, not current slave-selection
  // results. They remain stable from request acceptance through response.
  slave_index_t                     read_selected_slave_index_q;
  slave_index_t                     read_selected_slave_index_d;
  slave_index_t                     write_selected_slave_index_q;
  slave_index_t                     write_selected_slave_index_d;

  logic           [SLAVE_COUNT-1:0] read_slave_select_vector;
  logic           [SLAVE_COUNT-1:0] write_slave_select_vector;
  logic           [       XLEN-1:0] write_slave_select_addr;
  logic                             read_slave_selection_present;
  logic                             write_slave_selection_present;
  slave_index_t                     read_slave_select_index;
  slave_index_t                     write_slave_select_index;

  // AW and W are independent AXI channels. Capture them independently before
  // forwarding the baseline write transaction. This deliberately prioritizes
  // protocol correctness; a measured write fast path can be added later.
  axi_lite_addr_t                   buffered_write_addr_q;
  axi_lite_addr_t                   buffered_write_addr_d;
  axi_lite_w_t                      buffered_write_data_q;
  axi_lite_w_t                      buffered_write_data_d;
  logic                             buffered_write_addr_present_q;
  logic                             buffered_write_addr_present_d;
  logic                             buffered_write_data_present_q;
  logic                             buffered_write_data_present_d;

  logic                             selected_slave_aw_handshake_occurred_q;
  logic                             selected_slave_aw_handshake_occurred_d;
  logic                             selected_slave_w_handshake_occurred_q;
  logic                             selected_slave_w_handshake_occurred_d;

  logic                             npc_ar_handshake;
  logic                             npc_r_handshake;
  logic                             npc_aw_handshake;
  logic                             npc_w_handshake;
  logic                             npc_b_handshake;
  logic                             selected_slave_aw_handshake;
  logic                             selected_slave_w_handshake;

  assign npc_ar_handshake = npc_axi_arvalid_i && npc_axi_arready_o;
  assign npc_r_handshake  = npc_axi_rvalid_o && npc_axi_rready_i;
  assign npc_aw_handshake = npc_axi_awvalid_i && npc_axi_awready_o;
  assign npc_w_handshake  = npc_axi_wvalid_i && npc_axi_wready_o;
  assign npc_b_handshake  = npc_axi_bvalid_o && npc_axi_bready_i;

  // Preserve every selection bit so overlapping address regions can be checked.
  // A valid address map makes the returned vector one-hot-or-zero.
  function automatic logic [SLAVE_COUNT-1:0] select_slaves_by_addr(input logic [XLEN-1:0] addr);
    select_slaves_by_addr = '0;
    for (int unsigned i = 0; i < SLAVE_COUNT; i++) begin
      select_slaves_by_addr[i] =
          ((addr & SLAVE_ADDR_MASK[i]) == (SLAVE_BASE_ADDR[i] & SLAVE_ADDR_MASK[i]));
    end
  endfunction

  // The result is meaningful only while the corresponding selection-present
  // signal is asserted. An all-zero vector also converts to index zero.
  function automatic slave_index_t slave_select_vector_to_index(
      input logic [SLAVE_COUNT-1:0] slave_select_vector);
    slave_select_vector_to_index = '0;
    for (int unsigned i = 0; i < SLAVE_COUNT; i++) begin
      if (slave_select_vector[i]) begin
        slave_select_vector_to_index = slave_index_t'(i);
      end
    end
  endfunction

  // Read selection uses the current AR address. Write selection uses a newly
  // accepted AW address immediately; otherwise it uses the buffered AW address.
  // This preserves the current write target before buffered_write_addr_q updates
  // at the next clock edge.
  assign write_slave_select_addr =
      npc_aw_handshake ? npc_axi_aw_i.addr : buffered_write_addr_q.addr;
  assign read_slave_select_vector = select_slaves_by_addr(npc_axi_ar_i.addr);
  assign write_slave_select_vector = select_slaves_by_addr(write_slave_select_addr);
  assign read_slave_selection_present = |read_slave_select_vector;
  assign write_slave_selection_present = |write_slave_select_vector;
  assign read_slave_select_index = slave_select_vector_to_index(read_slave_select_vector);
  assign write_slave_select_index = slave_select_vector_to_index(write_slave_select_vector);

  assign selected_slave_aw_handshake =
      slave_axi_awvalid_o[write_selected_slave_index_q] &&
      slave_axi_awready_i[write_selected_slave_index_q];
  assign selected_slave_w_handshake =
      slave_axi_wvalid_o[write_selected_slave_index_q] &&
      slave_axi_wready_i[write_selected_slave_index_q];

  // Mapped AR requests use a combinational fast path to the selected slave.
  // Requests without a selected slave are accepted locally and receive DECERR.
  always_comb begin
    npc_axi_arready_o = 1'b0;
    npc_axi_r_o       = '0;
    npc_axi_rvalid_o  = 1'b0;

    for (int unsigned i = 0; i < SLAVE_COUNT; i++) begin
      slave_axi_ar_o[i]      = '0;
      slave_axi_arvalid_o[i] = 1'b0;
      slave_axi_rready_o[i]  = 1'b0;
    end

    unique case (read_state_q)
      READ_ACCEPT_AR: begin
        if (npc_axi_arvalid_i && read_slave_selection_present) begin
          slave_axi_arvalid_o[read_slave_select_index] = npc_axi_arvalid_i;
          npc_axi_arready_o                            = slave_axi_arready_i[read_slave_select_index];
          slave_axi_ar_o[read_slave_select_index]      = npc_axi_ar_i;
        end else begin
          npc_axi_arready_o = 1'b1;
        end
      end

      READ_WAIT_R: begin
        npc_axi_rvalid_o                                = slave_axi_rvalid_i[read_selected_slave_index_q];
        slave_axi_rready_o[read_selected_slave_index_q] = npc_axi_rready_i;
        npc_axi_r_o                                     = slave_axi_r_i[read_selected_slave_index_q];
      end

      READ_RETURN_DECERR: begin
        npc_axi_r_o.data = '0;
        npc_axi_r_o.resp = AXI_RESP_DECERR;
        npc_axi_rvalid_o = 1'b1;
      end

      default: ;
    endcase
  end

  // Keep the selected route until the corresponding R handshake completes.
  always_comb begin
    read_state_d                = read_state_q;
    read_selected_slave_index_d = read_selected_slave_index_q;

    unique case (read_state_q)
      READ_ACCEPT_AR: begin
        if (npc_ar_handshake) begin
          if (read_slave_selection_present) begin
            read_selected_slave_index_d = read_slave_select_index;
            read_state_d                = READ_WAIT_R;
          end else begin
            read_state_d = READ_RETURN_DECERR;
          end
        end
      end
      READ_WAIT_R, READ_RETURN_DECERR: begin
        if (npc_r_handshake) read_state_d = READ_ACCEPT_AR;
      end
      default: read_state_d = READ_ACCEPT_AR;
    endcase
  end

  // AW and W are collected independently, then forwarded independently to the
  // selected slave. A channel stops asserting VALID after its own handshake.
  always_comb begin
    npc_axi_awready_o = 1'b0;
    npc_axi_wready_o  = 1'b0;
    npc_axi_b_o       = '0;
    npc_axi_bvalid_o  = 1'b0;

    for (int unsigned i = 0; i < SLAVE_COUNT; i++) begin
      slave_axi_aw_o[i]      = '0;
      slave_axi_awvalid_o[i] = 1'b0;
      slave_axi_w_o[i]       = '0;
      slave_axi_wvalid_o[i]  = 1'b0;
      slave_axi_bready_o[i]  = 1'b0;
    end

    unique case (write_state_q)
      WRITE_COLLECT_AW_W: begin
        npc_axi_awready_o = !buffered_write_addr_present_q;
        npc_axi_wready_o  = !buffered_write_data_present_q;
      end

      WRITE_FORWARD_AW_W: begin
        slave_axi_aw_o[write_selected_slave_index_q]      = buffered_write_addr_q;
        slave_axi_awvalid_o[write_selected_slave_index_q] = !selected_slave_aw_handshake_occurred_q;
        slave_axi_w_o[write_selected_slave_index_q]       = buffered_write_data_q;
        slave_axi_wvalid_o[write_selected_slave_index_q]  = !selected_slave_w_handshake_occurred_q;
      end

      WRITE_WAIT_B: begin
        npc_axi_b_o                                      = slave_axi_b_i[write_selected_slave_index_q];
        npc_axi_bvalid_o                                 = slave_axi_bvalid_i[write_selected_slave_index_q];
        slave_axi_bready_o[write_selected_slave_index_q] = npc_axi_bready_i;
      end

      WRITE_RETURN_DECERR: begin
        npc_axi_b_o.resp = AXI_RESP_DECERR;
        npc_axi_bvalid_o = 1'b1;
      end

      default: ;
    endcase
  end

  // Buffer validity is retained through the B response so forwarded payloads
  // remain stable under downstream backpressure.
  always_comb begin
    write_state_d                          = write_state_q;
    write_selected_slave_index_d           = write_selected_slave_index_q;
    buffered_write_addr_d                  = buffered_write_addr_q;
    buffered_write_data_d                  = buffered_write_data_q;
    buffered_write_addr_present_d          = buffered_write_addr_present_q;
    buffered_write_data_present_d          = buffered_write_data_present_q;
    selected_slave_aw_handshake_occurred_d = selected_slave_aw_handshake_occurred_q;
    selected_slave_w_handshake_occurred_d  = selected_slave_w_handshake_occurred_q;

    unique case (write_state_q)
      WRITE_COLLECT_AW_W: begin
        if (npc_aw_handshake) begin
          buffered_write_addr_d     = npc_axi_aw_i;
          buffered_write_addr_present_d = 1'b1;
        end

        if (npc_w_handshake) begin
          buffered_write_data_d     = npc_axi_w_i;
          buffered_write_data_present_d = 1'b1;
        end

        if ((buffered_write_addr_present_q || npc_aw_handshake) &&
            (buffered_write_data_present_q || npc_w_handshake)) begin
          selected_slave_aw_handshake_occurred_d = 1'b0;
          selected_slave_w_handshake_occurred_d  = 1'b0;

          if (write_slave_selection_present) begin
            write_selected_slave_index_d = write_slave_select_index;
            write_state_d                = WRITE_FORWARD_AW_W;
          end else begin
            write_state_d = WRITE_RETURN_DECERR;
          end
        end
      end

      WRITE_FORWARD_AW_W: begin
        if (selected_slave_aw_handshake) begin
          selected_slave_aw_handshake_occurred_d = 1'b1;
        end
        if (selected_slave_w_handshake) begin
          selected_slave_w_handshake_occurred_d = 1'b1;
        end

        if ((selected_slave_aw_handshake_occurred_q || selected_slave_aw_handshake) &&
            (selected_slave_w_handshake_occurred_q || selected_slave_w_handshake)) begin
          write_state_d = WRITE_WAIT_B;
        end
      end

      WRITE_WAIT_B, WRITE_RETURN_DECERR: begin
        if (npc_b_handshake) begin
          write_state_d                          = WRITE_COLLECT_AW_W;
          buffered_write_addr_present_d          = 1'b0;
          buffered_write_data_present_d          = 1'b0;
          selected_slave_aw_handshake_occurred_d = 1'b0;
          selected_slave_w_handshake_occurred_d  = 1'b0;
        end
      end

      default: begin
        write_state_d                          = WRITE_COLLECT_AW_W;
        buffered_write_addr_present_d          = 1'b0;
        buffered_write_data_present_d          = 1'b0;
        selected_slave_aw_handshake_occurred_d = 1'b0;
        selected_slave_w_handshake_occurred_d  = 1'b0;
      end
    endcase
  end

  // State and transaction-route registers. This is the only block that writes
  // q signals; combinational blocks above write only d signals and outputs.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q                           <= READ_ACCEPT_AR;
      read_selected_slave_index_q            <= '0;
      write_state_q                          <= WRITE_COLLECT_AW_W;
      write_selected_slave_index_q           <= '0;
      buffered_write_addr_q                  <= '0;
      buffered_write_data_q                  <= '0;
      buffered_write_addr_present_q          <= 1'b0;
      buffered_write_data_present_q          <= 1'b0;
      selected_slave_aw_handshake_occurred_q <= 1'b0;
      selected_slave_w_handshake_occurred_q  <= 1'b0;
    end else begin
      read_state_q                           <= read_state_d;
      read_selected_slave_index_q            <= read_selected_slave_index_d;
      write_state_q                          <= write_state_d;
      write_selected_slave_index_q           <= write_selected_slave_index_d;
      buffered_write_addr_q                  <= buffered_write_addr_d;
      buffered_write_data_q                  <= buffered_write_data_d;
      buffered_write_addr_present_q          <= buffered_write_addr_present_d;
      buffered_write_data_present_q          <= buffered_write_data_present_d;
      selected_slave_aw_handshake_occurred_q <= selected_slave_aw_handshake_occurred_d;
      selected_slave_w_handshake_occurred_q  <= selected_slave_w_handshake_occurred_d;
    end
  end

  initial begin
    p_slave_count_positive :
    assert (SLAVE_COUNT > 0) else $fatal(1, "AXI-Lite xbar requires at least one slave");
  end

  p_read_slave_selection_not_overlapping :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    read_state_q == READ_ACCEPT_AR && npc_axi_arvalid_i
    |-> $onehot0(read_slave_select_vector)
  ) else $error("Read address selected overlapping AXI-Lite slave regions");

  p_write_slave_selection_not_overlapping :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    write_state_q == WRITE_COLLECT_AW_W &&
    (buffered_write_addr_present_q || npc_aw_handshake)
    |-> $onehot0(write_slave_select_vector)
  ) else $error("Write address selected overlapping AXI-Lite slave regions");

  p_npc_r_stable_while_stalled :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    npc_axi_rvalid_o && !npc_axi_rready_i
    |=> npc_axi_rvalid_o && $stable(npc_axi_r_o)
  ) else $error("Xbar R channel changed while stalled");

  p_npc_b_stable_while_stalled :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    npc_axi_bvalid_o && !npc_axi_bready_i
    |=> npc_axi_bvalid_o && $stable(npc_axi_b_o)
  ) else $error("Xbar B channel changed while stalled");

  p_read_selected_slave_index_stable :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    read_state_q == READ_WAIT_R
    |=> $stable(read_selected_slave_index_q)
  ) else $error("Selected read slave index changed during an outstanding transaction");

  p_write_selected_slave_index_stable :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    write_state_q inside {WRITE_FORWARD_AW_W, WRITE_WAIT_B}
    |=> $stable(write_selected_slave_index_q)
  ) else $error("Selected write slave index changed during an outstanding transaction");

  p_npc_r_requires_outstanding_read :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    npc_axi_rvalid_o |-> read_state_q inside {READ_WAIT_R, READ_RETURN_DECERR}
  ) else $error("Xbar returned R without an outstanding read transaction");

  p_npc_b_requires_outstanding_write :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    npc_axi_bvalid_o |-> write_state_q inside {WRITE_WAIT_B, WRITE_RETURN_DECERR}
  ) else $error("Xbar returned B without an outstanding write transaction");

  for (genvar i = 0; i < SLAVE_COUNT; i++) begin : gen_slave_channel_assertions
    p_slave_ar_stable_while_stalled :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      slave_axi_arvalid_o[i] && !slave_axi_arready_i[i]
      |=> slave_axi_arvalid_o[i] && $stable(slave_axi_ar_o[i])
    ) else $error("Slave %0d AR channel changed while stalled", i);

    p_slave_aw_stable_while_stalled :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      slave_axi_awvalid_o[i] && !slave_axi_awready_i[i]
      |=> slave_axi_awvalid_o[i] && $stable(slave_axi_aw_o[i])
    ) else $error("Slave %0d AW channel changed while stalled", i);

    p_slave_w_stable_while_stalled :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      slave_axi_wvalid_o[i] && !slave_axi_wready_i[i]
      |=> slave_axi_wvalid_o[i] && $stable(slave_axi_w_o[i])
    ) else $error("Slave %0d W channel changed while stalled", i);

    for (genvar j = i + 1; j < SLAVE_COUNT; j++) begin : gen_distinct_slave_assertions
      p_only_one_slave_channel_selected :
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        !((slave_axi_arvalid_o[i] && slave_axi_arvalid_o[j]) ||
          (slave_axi_awvalid_o[i] && slave_axi_awvalid_o[j]) ||
          (slave_axi_wvalid_o[i]  && slave_axi_wvalid_o[j])  ||
          (slave_axi_rready_o[i]  && slave_axi_rready_o[j])  ||
          (slave_axi_bready_o[i]  && slave_axi_bready_o[j]))
      ) else $error("One AXI-Lite channel selected slaves %0d and %0d together", i, j);
    end
  end

  // NOTE(XBAR-WRITE-FAST-PATH): Do not implement this until the buffered
  // baseline passes AW-before-W, W-before-AW, simultaneous AW/W, DECERR, and
  // random-backpressure tests. A later fast path may directly forward mapped
  // AW/W from WRITE_COLLECT_AW_W, but it must preserve independent channel
  // handshakes and fall back to the buffers on either stalled channel. Compare
  // latency and STA before accepting that optimization.

endmodule
