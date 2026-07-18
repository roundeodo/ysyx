// Simulation shell. Synthesizable CPU and AXI arbitration live in
// riscv32_npc_axi_lite; this module only attaches the DPI-backed memory and
// simulator debug hooks.
module top
  import riscv32_pkg::*;
#(
    parameter int unsigned SIM_IFU_READ_LATENCY   = 1,
    parameter int unsigned SIM_LSU_READ_LATENCY   = 1,
    parameter int unsigned SIM_LSU_WRITE_LATENCY  = 1,
    parameter int unsigned SIM_RANDOM_LATENCY_MAX = 20
) (
    input logic clk,
    input logic rstn
);
  axi_lite_addr_t mem_axi_ar;
  logic           mem_axi_arvalid;
  logic           mem_axi_arready;
  axi_lite_r_t    mem_axi_r;
  logic           mem_axi_rvalid;
  logic           mem_axi_rready;

  axi_lite_addr_t mem_axi_aw;
  logic           mem_axi_awvalid;
  logic           mem_axi_awready;
  axi_lite_w_t    mem_axi_w;
  logic           mem_axi_wvalid;
  logic           mem_axi_wready;
  axi_lite_b_t    mem_axi_b;
  logic           mem_axi_bvalid;
  logic           mem_axi_bready;

  riscv32_npc_axi_lite u_npc_axi_lite (
      .clk_i            (clk),
      .rst_ni           (rstn),
      .mem_axi_ar_o     (mem_axi_ar),
      .mem_axi_arvalid_o(mem_axi_arvalid),
      .mem_axi_arready_i(mem_axi_arready),
      .mem_axi_r_i      (mem_axi_r),
      .mem_axi_rvalid_i (mem_axi_rvalid),
      .mem_axi_rready_o (mem_axi_rready),
      .mem_axi_aw_o     (mem_axi_aw),
      .mem_axi_awvalid_o(mem_axi_awvalid),
      .mem_axi_awready_i(mem_axi_awready),
      .mem_axi_w_o      (mem_axi_w),
      .mem_axi_wvalid_o (mem_axi_wvalid),
      .mem_axi_wready_i (mem_axi_wready),
      .mem_axi_b_i      (mem_axi_b),
      .mem_axi_bvalid_i (mem_axi_bvalid),
      .mem_axi_bready_o (mem_axi_bready)
  );

  riscv32_sim_mem #(
      .IFU_READ_LATENCY  (SIM_IFU_READ_LATENCY),
      .LSU_READ_LATENCY  (SIM_LSU_READ_LATENCY),
      .LSU_WRITE_LATENCY (SIM_LSU_WRITE_LATENCY),
      .RANDOM_LATENCY_MAX(SIM_RANDOM_LATENCY_MAX)
  ) u_sim_mem (
      .clk_i            (clk),
      .rst_ni           (rstn),
      .mem_axi_ar_i     (mem_axi_ar),
      .mem_axi_arvalid_i(mem_axi_arvalid),
      .mem_axi_arready_o(mem_axi_arready),
      .mem_axi_r_o      (mem_axi_r),
      .mem_axi_rvalid_o (mem_axi_rvalid),
      .mem_axi_rready_i (mem_axi_rready),
      .mem_axi_aw_i     (mem_axi_aw),
      .mem_axi_awvalid_i(mem_axi_awvalid),
      .mem_axi_awready_o(mem_axi_awready),
      .mem_axi_w_i      (mem_axi_w),
      .mem_axi_wvalid_i (mem_axi_wvalid),
      .mem_axi_wready_o (mem_axi_wready),
      .mem_axi_b_o      (mem_axi_b),
      .mem_axi_bvalid_o (mem_axi_bvalid),
      .mem_axi_bready_i (mem_axi_bready)
  );

  import "DPI-C" context function void npc_set_dpi_scope();
  import "DPI-C" context function void ebreak_halt();

  initial begin
    npc_set_dpi_scope();
  end

  export "DPI-C" function npc_get_pc_dpi;
  export "DPI-C" function npc_get_inst_dpi;
  export "DPI-C" function npc_get_commit_valid_dpi;
  export "DPI-C" function npc_get_commit_pc_dpi;
  export "DPI-C" function npc_get_commit_inst_dpi;
  export "DPI-C" function npc_get_commit_next_pc_dpi;
  export "DPI-C" function npc_get_gpr_dpi;

  function int npc_get_pc_dpi();
    npc_get_pc_dpi = u_npc_axi_lite.u_core.fetch_entry.pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = u_npc_axi_lite.u_core.fetch_entry.instruction;
  endfunction

  function int npc_get_commit_valid_dpi();
    npc_get_commit_valid_dpi = int'(u_npc_axi_lite.u_core.commit_valid);
  endfunction

  function int npc_get_commit_pc_dpi();
    npc_get_commit_pc_dpi = u_npc_axi_lite.u_core.commit.pc;
  endfunction

  function int npc_get_commit_inst_dpi();
    npc_get_commit_inst_dpi = u_npc_axi_lite.u_core.commit.instruction;
  endfunction

  function int npc_get_commit_next_pc_dpi();
    if (u_npc_axi_lite.u_core.selected_redirect_req_valid &&
        u_npc_axi_lite.u_core.commit_valid &&
        (u_npc_axi_lite.u_core.selected_redirect_req.source_pc ==
         u_npc_axi_lite.u_core.commit.pc)) begin
      npc_get_commit_next_pc_dpi = u_npc_axi_lite.u_core.selected_redirect_req.target_pc;
    end else begin
      npc_get_commit_next_pc_dpi = u_npc_axi_lite.u_core.commit.next_pc;
    end
  endfunction

  function int npc_get_gpr_dpi(input int index);
    if ((index <= 0) || (index >= ARCH_REG_NUM)) begin
      npc_get_gpr_dpi = '0;
    end else begin
      npc_get_gpr_dpi = u_npc_axi_lite.u_core.u_arch_regfile.gpr_q[index];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (u_npc_axi_lite.u_core.commit_valid &&
        (u_npc_axi_lite.u_core.commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end

endmodule
