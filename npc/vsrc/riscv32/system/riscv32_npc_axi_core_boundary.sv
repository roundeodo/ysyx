// Synthesizable NPC integration boundary used by SoC integration and STA.
// The core and arbiter use AXI4-Lite internally. This boundary expands each
// internal transaction into one full-AXI, single-beat transaction.
module riscv32_npc_axi_core_boundary
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    output axi_addr_t master_axi_ar_o,
    output logic      master_axi_arvalid_o,
    input  logic      master_axi_arready_i,
    // This restricted master has one outstanding, single-beat transaction, so
    // the returning RID/RLAST and BID do not participate in routing yet.
    /* verilator lint_off UNUSEDSIGNAL */
    input  axi_r_t    master_axi_r_i,
    input  logic      master_axi_rvalid_i,
    output logic      master_axi_rready_o,

    output axi_addr_t master_axi_aw_o,
    output logic      master_axi_awvalid_o,
    input  logic      master_axi_awready_i,
    output axi_w_t    master_axi_w_o,
    output logic      master_axi_wvalid_o,
    input  logic      master_axi_wready_i,
    input  axi_b_t    master_axi_b_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic      master_axi_bvalid_i,
    output logic      master_axi_bready_o
);
  localparam int unsigned AXI_ROUTE_DESTINATION_COUNT = 2;
  localparam int unsigned CLINT_DESTINATION_INDEX      = 0;
  localparam int unsigned SOC_DESTINATION_INDEX        = 1;

  localparam logic [XLEN-1:0] AXI_ROUTE_BASE_ADDR_ARRAY[AXI_ROUTE_DESTINATION_COUNT] =
      '{32'h0200_0000, 32'h0000_0000};
  localparam logic [XLEN-1:0] AXI_ROUTE_ADDR_MASK_ARRAY[AXI_ROUTE_DESTINATION_COUNT] =
      '{32'hffff_0000, 32'h0000_0000};
  // Only CLINT participates in address comparison. Every address outside the
  // CLINT window is sent to the SoC-facing destination by the default route.
  localparam logic AXI_ROUTE_ADDR_SELECT_ENABLE_ARRAY[AXI_ROUTE_DESTINATION_COUNT] =
      '{1'b1, 1'b0};

  axi_lite_addr_t ifu_axi_ar;
  logic           ifu_axi_arvalid;
  logic           ifu_axi_arready;
  axi_lite_r_t    ifu_axi_r;
  logic           ifu_axi_rvalid;
  logic           ifu_axi_rready;

  axi_lite_addr_t lsu_axi_ar;
  logic           lsu_axi_arvalid;
  logic           lsu_axi_arready;
  axi_lite_r_t    lsu_axi_r;
  logic           lsu_axi_rvalid;
  logic           lsu_axi_rready;

  axi_lite_addr_t lsu_axi_aw;
  logic           lsu_axi_awvalid;
  logic           lsu_axi_awready;
  axi_lite_w_t    lsu_axi_w;
  logic           lsu_axi_wvalid;
  logic           lsu_axi_wready;
  axi_lite_b_t    lsu_axi_b;
  logic           lsu_axi_bvalid;
  logic           lsu_axi_bready;

  // AxPROT is an AXI4-Lite attribute used inside the core but is not present in
  // the current SoC-facing axi_addr_t definition.
  /* verilator lint_off UNUSEDSIGNAL */
  axi_lite_addr_t arbiter_axi_ar;
  logic           arbiter_axi_arvalid;
  logic           arbiter_axi_arready;
  axi_lite_r_t    arbiter_axi_r;
  logic           arbiter_axi_rvalid;
  logic           arbiter_axi_rready;

  axi_lite_addr_t arbiter_axi_aw;
  /* verilator lint_on UNUSEDSIGNAL */
  logic           arbiter_axi_awvalid;
  logic           arbiter_axi_awready;
  axi_lite_w_t    arbiter_axi_w;
  logic           arbiter_axi_wvalid;
  logic           arbiter_axi_wready;
  axi_lite_b_t    arbiter_axi_b;
  logic           arbiter_axi_bvalid;
  logic           arbiter_axi_bready;

  axi_lite_addr_t destination_axi_ar_array     [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_arvalid_array[AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_arready_array[AXI_ROUTE_DESTINATION_COUNT];
  axi_lite_r_t    destination_axi_r_array      [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_rvalid_array [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_rready_array [AXI_ROUTE_DESTINATION_COUNT];

  axi_lite_addr_t destination_axi_aw_array     [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_awvalid_array[AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_awready_array[AXI_ROUTE_DESTINATION_COUNT];
  axi_lite_w_t    destination_axi_w_array      [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_wvalid_array [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_wready_array [AXI_ROUTE_DESTINATION_COUNT];
  axi_lite_b_t    destination_axi_b_array      [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_bvalid_array [AXI_ROUTE_DESTINATION_COUNT];
  logic           destination_axi_bready_array [AXI_ROUTE_DESTINATION_COUNT];

  localparam logic [XLEN-1:0] SOC_UART_BASE_ADDR = 32'h1000_0000;
  localparam logic [XLEN-1:0] SOC_UART_ADDR_MASK = 32'hffff_f000;

  logic [2:0] soc_read_transfer_size;
  logic [2:0] soc_write_transfer_size;

  // The core-side bus is AXI4-Lite and therefore carries no AxSIZE. At the
  // ysyxSoC full-AXI boundary, recover write size from WSTRB. Read size cannot
  // be recovered from a Lite read payload, so byte-addressed UART accesses are
  // identified from the SoC address map; normal instruction/data memory reads
  // remain 32-bit transfers.
  always_comb begin
    soc_read_transfer_size = 3'd2;
    if ((destination_axi_ar_array[SOC_DESTINATION_INDEX].addr & SOC_UART_ADDR_MASK) ==
        SOC_UART_BASE_ADDR) begin
      soc_read_transfer_size = 3'd0;
    end

    unique case (destination_axi_w_array[SOC_DESTINATION_INDEX].strb)
      4'b0001, 4'b0010, 4'b0100, 4'b1000: soc_write_transfer_size = 3'd0;
      4'b0011, 4'b1100:                   soc_write_transfer_size = 3'd1;
      default:                            soc_write_transfer_size = 3'd2;
    endcase
  end

  // The current core issues one transaction at a time. Full AXI therefore uses
  // ID 0, one beat, and INCR burst semantics at this boundary.
  always_comb begin
    master_axi_ar_o = '{
      addr  : destination_axi_ar_array[SOC_DESTINATION_INDEX].addr,
      id    : 4'b0,
      len   : 8'b0,
      size  : soc_read_transfer_size,
      burst : 2'b01
    };
    master_axi_aw_o = '{
      addr  : destination_axi_aw_array[SOC_DESTINATION_INDEX].addr,
      id    : 4'b0,
      len   : 8'b0,
      size  : soc_write_transfer_size,
      burst : 2'b01
    };
    master_axi_w_o = '{
      data : destination_axi_w_array[SOC_DESTINATION_INDEX].data,
      strb : destination_axi_w_array[SOC_DESTINATION_INDEX].strb,
      last : 1'b1
    };

    destination_axi_r_array[SOC_DESTINATION_INDEX] = '{
      data : master_axi_r_i.data,
      resp : master_axi_r_i.resp
    };
    destination_axi_b_array[SOC_DESTINATION_INDEX] = '{resp: master_axi_b_i.resp};
  end

  assign master_axi_arvalid_o = destination_axi_arvalid_array[SOC_DESTINATION_INDEX];
  assign destination_axi_arready_array[SOC_DESTINATION_INDEX] = master_axi_arready_i;
  assign destination_axi_rvalid_array[SOC_DESTINATION_INDEX]  = master_axi_rvalid_i;
  assign master_axi_rready_o = destination_axi_rready_array[SOC_DESTINATION_INDEX];

  assign master_axi_awvalid_o = destination_axi_awvalid_array[SOC_DESTINATION_INDEX];
  assign destination_axi_awready_array[SOC_DESTINATION_INDEX] = master_axi_awready_i;
  assign master_axi_wvalid_o = destination_axi_wvalid_array[SOC_DESTINATION_INDEX];
  assign destination_axi_wready_array[SOC_DESTINATION_INDEX] = master_axi_wready_i;
  assign destination_axi_bvalid_array[SOC_DESTINATION_INDEX] = master_axi_bvalid_i;
  assign master_axi_bready_o = destination_axi_bready_array[SOC_DESTINATION_INDEX];

  riscv32_core u_core (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .ifu_axi_ar_o     (ifu_axi_ar),
      .ifu_axi_arvalid_o(ifu_axi_arvalid),
      .ifu_axi_arready_i(ifu_axi_arready),
      .ifu_axi_r_i      (ifu_axi_r),
      .ifu_axi_rvalid_i (ifu_axi_rvalid),
      .ifu_axi_rready_o (ifu_axi_rready),
      .lsu_axi_ar_o     (lsu_axi_ar),
      .lsu_axi_arvalid_o(lsu_axi_arvalid),
      .lsu_axi_arready_i(lsu_axi_arready),
      .lsu_axi_r_i      (lsu_axi_r),
      .lsu_axi_rvalid_i (lsu_axi_rvalid),
      .lsu_axi_rready_o (lsu_axi_rready),
      .lsu_axi_aw_o     (lsu_axi_aw),
      .lsu_axi_awvalid_o(lsu_axi_awvalid),
      .lsu_axi_awready_i(lsu_axi_awready),
      .lsu_axi_w_o      (lsu_axi_w),
      .lsu_axi_wvalid_o (lsu_axi_wvalid),
      .lsu_axi_wready_i (lsu_axi_wready),
      .lsu_axi_b_i      (lsu_axi_b),
      .lsu_axi_bvalid_i (lsu_axi_bvalid),
      .lsu_axi_bready_o (lsu_axi_bready)
  );

  riscv32_axi_lite_arbiter u_axi_lite_arbiter (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .ifu_axi_ar_i     (ifu_axi_ar),
      .ifu_axi_arvalid_i(ifu_axi_arvalid),
      .ifu_axi_arready_o(ifu_axi_arready),
      .ifu_axi_r_o      (ifu_axi_r),
      .ifu_axi_rvalid_o (ifu_axi_rvalid),
      .ifu_axi_rready_i (ifu_axi_rready),
      .lsu_axi_ar_i     (lsu_axi_ar),
      .lsu_axi_arvalid_i(lsu_axi_arvalid),
      .lsu_axi_arready_o(lsu_axi_arready),
      .lsu_axi_r_o      (lsu_axi_r),
      .lsu_axi_rvalid_o (lsu_axi_rvalid),
      .lsu_axi_rready_i (lsu_axi_rready),
      .lsu_axi_aw_i     (lsu_axi_aw),
      .lsu_axi_awvalid_i(lsu_axi_awvalid),
      .lsu_axi_awready_o(lsu_axi_awready),
      .lsu_axi_w_i      (lsu_axi_w),
      .lsu_axi_wvalid_i (lsu_axi_wvalid),
      .lsu_axi_wready_o (lsu_axi_wready),
      .lsu_axi_b_o      (lsu_axi_b),
      .lsu_axi_bvalid_o (lsu_axi_bvalid),
      .lsu_axi_bready_i (lsu_axi_bready),
      .mem_axi_ar_o     (arbiter_axi_ar),
      .mem_axi_arvalid_o(arbiter_axi_arvalid),
      .mem_axi_arready_i(arbiter_axi_arready),
      .mem_axi_r_i      (arbiter_axi_r),
      .mem_axi_rvalid_i (arbiter_axi_rvalid),
      .mem_axi_rready_o (arbiter_axi_rready),
      .mem_axi_aw_o     (arbiter_axi_aw),
      .mem_axi_awvalid_o(arbiter_axi_awvalid),
      .mem_axi_awready_i(arbiter_axi_awready),
      .mem_axi_w_o      (arbiter_axi_w),
      .mem_axi_wvalid_o (arbiter_axi_wvalid),
      .mem_axi_wready_i (arbiter_axi_wready),
      .mem_axi_b_i      (arbiter_axi_b),
      .mem_axi_bvalid_i (arbiter_axi_bvalid),
      .mem_axi_bready_o (arbiter_axi_bready)
  );

  // Keep the architectural CLINT inside the CPU boundary. The xbar performs
  // address selection and preserves the route until the corresponding AXI
  // response completes. Its empty-path forwarding keeps the existing
  // combinational fast bypass for both CLINT and SoC requests.
  riscv32_axi_lite_xbar #(
      .SLAVE_COUNT            (AXI_ROUTE_DESTINATION_COUNT),
      .SLAVE_BASE_ADDR        (AXI_ROUTE_BASE_ADDR_ARRAY),
      .SLAVE_ADDR_MASK        (AXI_ROUTE_ADDR_MASK_ARRAY),
      .SLAVE_ADDR_SELECT_ENABLE(AXI_ROUTE_ADDR_SELECT_ENABLE_ARRAY),
      .DEFAULT_SLAVE_ENABLE   (1'b1),
      .DEFAULT_SLAVE_INDEX    (SOC_DESTINATION_INDEX)
  ) u_axi_lite_address_router (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .npc_axi_ar_i       (arbiter_axi_ar),
      .npc_axi_arvalid_i  (arbiter_axi_arvalid),
      .npc_axi_arready_o  (arbiter_axi_arready),
      .npc_axi_r_o        (arbiter_axi_r),
      .npc_axi_rvalid_o   (arbiter_axi_rvalid),
      .npc_axi_rready_i   (arbiter_axi_rready),
      .npc_axi_aw_i       (arbiter_axi_aw),
      .npc_axi_awvalid_i  (arbiter_axi_awvalid),
      .npc_axi_awready_o  (arbiter_axi_awready),
      .npc_axi_w_i        (arbiter_axi_w),
      .npc_axi_wvalid_i   (arbiter_axi_wvalid),
      .npc_axi_wready_o   (arbiter_axi_wready),
      .npc_axi_b_o        (arbiter_axi_b),
      .npc_axi_bvalid_o   (arbiter_axi_bvalid),
      .npc_axi_bready_i   (arbiter_axi_bready),
      .slave_axi_ar_o     (destination_axi_ar_array),
      .slave_axi_arvalid_o(destination_axi_arvalid_array),
      .slave_axi_arready_i(destination_axi_arready_array),
      .slave_axi_r_i      (destination_axi_r_array),
      .slave_axi_rvalid_i (destination_axi_rvalid_array),
      .slave_axi_rready_o (destination_axi_rready_array),
      .slave_axi_aw_o     (destination_axi_aw_array),
      .slave_axi_awvalid_o(destination_axi_awvalid_array),
      .slave_axi_awready_i(destination_axi_awready_array),
      .slave_axi_w_o      (destination_axi_w_array),
      .slave_axi_wvalid_o (destination_axi_wvalid_array),
      .slave_axi_wready_i (destination_axi_wready_array),
      .slave_axi_b_i      (destination_axi_b_array),
      .slave_axi_bvalid_i (destination_axi_bvalid_array),
      .slave_axi_bready_o (destination_axi_bready_array)
  );

  riscv32_axi_lite_clint #(
      .CLINT_BASE_ADDR(AXI_ROUTE_BASE_ADDR_ARRAY[CLINT_DESTINATION_INDEX])
  ) u_axi_lite_clint (
      .clk_i                (clk_i),
      .rst_ni               (rst_ni),
      .clint_axi_ar_i       (destination_axi_ar_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_arvalid_i  (destination_axi_arvalid_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_arready_o  (destination_axi_arready_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_r_o        (destination_axi_r_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_rvalid_o   (destination_axi_rvalid_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_rready_i   (destination_axi_rready_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_aw_i       (destination_axi_aw_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_awvalid_i  (destination_axi_awvalid_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_awready_o  (destination_axi_awready_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_w_i        (destination_axi_w_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_wvalid_i   (destination_axi_wvalid_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_wready_o   (destination_axi_wready_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_b_o        (destination_axi_b_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_bvalid_o   (destination_axi_bvalid_array[CLINT_DESTINATION_INDEX]),
      .clint_axi_bready_i   (destination_axi_bready_array[CLINT_DESTINATION_INDEX])
  );

endmodule
