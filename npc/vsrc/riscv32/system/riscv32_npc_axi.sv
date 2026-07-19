// Synthesizable NPC integration boundary used by SoC integration and STA.
// The core and arbiter use AXI4-Lite internally. This boundary expands each
// internal transaction into one full-AXI, single-beat transaction.
module riscv32_npc_axi
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    output axi_addr_t master_axi_ar_o,
    output logic      master_axi_arvalid_o,
    input  logic      master_axi_arready_i,
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
    input  logic      master_axi_bvalid_i,
    output logic      master_axi_bready_o
);
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

  axi_lite_addr_t shared_axi_ar;
  logic           shared_axi_arvalid;
  logic           shared_axi_arready;
  axi_lite_r_t    shared_axi_r;
  logic           shared_axi_rvalid;
  logic           shared_axi_rready;

  axi_lite_addr_t shared_axi_aw;
  logic           shared_axi_awvalid;
  logic           shared_axi_awready;
  axi_lite_w_t    shared_axi_w;
  logic           shared_axi_wvalid;
  logic           shared_axi_wready;
  axi_lite_b_t    shared_axi_b;
  logic           shared_axi_bvalid;
  logic           shared_axi_bready;

  // The current core issues one transaction at a time. Full AXI therefore uses
  // ID 0, one 32-bit beat, and INCR burst semantics at this boundary.
  always_comb begin
    master_axi_ar_o = '{
      addr  : shared_axi_ar.addr,
      id    : 4'b0,
      len   : 8'b0,
      size  : 3'd2,
      burst : 2'b01
    };
    master_axi_aw_o = '{
      addr  : shared_axi_aw.addr,
      id    : 4'b0,
      len   : 8'b0,
      size  : 3'd2,
      burst : 2'b01
    };
    master_axi_w_o = '{
      data : shared_axi_w.data,
      strb : shared_axi_w.strb,
      last : 1'b1
    };

    shared_axi_r = '{
      data : master_axi_r_i.data,
      resp : master_axi_r_i.resp
    };
    shared_axi_b = '{resp: master_axi_b_i.resp};
  end

  assign master_axi_arvalid_o = shared_axi_arvalid;
  assign shared_axi_arready   = master_axi_arready_i;
  assign shared_axi_rvalid    = master_axi_rvalid_i;
  assign master_axi_rready_o  = shared_axi_rready;

  assign master_axi_awvalid_o = shared_axi_awvalid;
  assign shared_axi_awready   = master_axi_awready_i;
  assign master_axi_wvalid_o  = shared_axi_wvalid;
  assign shared_axi_wready    = master_axi_wready_i;
  assign shared_axi_bvalid    = master_axi_bvalid_i;
  assign master_axi_bready_o  = shared_axi_bready;

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
      .mem_axi_ar_o     (shared_axi_ar),
      .mem_axi_arvalid_o(shared_axi_arvalid),
      .mem_axi_arready_i(shared_axi_arready),
      .mem_axi_r_i      (shared_axi_r),
      .mem_axi_rvalid_i (shared_axi_rvalid),
      .mem_axi_rready_o (shared_axi_rready),
      .mem_axi_aw_o     (shared_axi_aw),
      .mem_axi_awvalid_o(shared_axi_awvalid),
      .mem_axi_awready_i(shared_axi_awready),
      .mem_axi_w_o      (shared_axi_w),
      .mem_axi_wvalid_o (shared_axi_wvalid),
      .mem_axi_wready_i (shared_axi_wready),
      .mem_axi_b_i      (shared_axi_b),
      .mem_axi_bvalid_i (shared_axi_bvalid),
      .mem_axi_bready_o (shared_axi_bready)
  );

`ifndef SYNTHESIS
  property p_single_beat_read_response;
    @(posedge clk_i) disable iff (!rst_ni)
      master_axi_rvalid_i |-> (master_axi_r_i.id == 4'b0 && master_axi_r_i.last);
  endproperty
  assert property (p_single_beat_read_response);

  property p_single_id_write_response;
    @(posedge clk_i) disable iff (!rst_ni)
      master_axi_bvalid_i |-> (master_axi_b_i.id == 4'b0);
  endproperty
  assert property (p_single_id_write_response);
`endif

endmodule
