// Synthesizable NPC integration boundary used by SoC integration and STA.
// The core keeps independent instruction/data ports; this layer owns shared
// AXI4-Lite arbitration and exposes one memory-side master interface.
module riscv32_npc_axi_lite
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

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
      .mem_axi_ar_o     (mem_axi_ar_o),
      .mem_axi_arvalid_o(mem_axi_arvalid_o),
      .mem_axi_arready_i(mem_axi_arready_i),
      .mem_axi_r_i      (mem_axi_r_i),
      .mem_axi_rvalid_i (mem_axi_rvalid_i),
      .mem_axi_rready_o (mem_axi_rready_o),
      .mem_axi_aw_o     (mem_axi_aw_o),
      .mem_axi_awvalid_o(mem_axi_awvalid_o),
      .mem_axi_awready_i(mem_axi_awready_i),
      .mem_axi_w_o      (mem_axi_w_o),
      .mem_axi_wvalid_o (mem_axi_wvalid_o),
      .mem_axi_wready_i (mem_axi_wready_i),
      .mem_axi_b_i      (mem_axi_b_i),
      .mem_axi_bvalid_i (mem_axi_bvalid_i),
      .mem_axi_bready_o (mem_axi_bready_o)
  );

endmodule
