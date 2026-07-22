// ysyxSoC CPU boundary. The external port names and widths must match
// ysyxSoC/spec/cpu-interface.md exactly; structured payloads remain internal.
module riscv32_npc_axi
  import riscv32_pkg::*;
(
    input  logic        clock,
    input  logic        reset,

    // External interrupts are not consumed by the current single-cycle core.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        io_interrupt,

    input  logic        io_master_awready,
    output logic        io_master_awvalid,
    output logic [31:0] io_master_awaddr,
    output logic [3:0]  io_master_awid,
    output logic [7:0]  io_master_awlen,
    output logic [2:0]  io_master_awsize,
    output logic [1:0]  io_master_awburst,

    input  logic        io_master_wready,
    output logic        io_master_wvalid,
    output logic [31:0] io_master_wdata,
    output logic [3:0]  io_master_wstrb,
    output logic        io_master_wlast,

    output logic        io_master_bready,
    input  logic        io_master_bvalid,
    input  logic [1:0]  io_master_bresp,
    input  logic [3:0]  io_master_bid,

    input  logic        io_master_arready,
    output logic        io_master_arvalid,
    output logic [31:0] io_master_araddr,
    output logic [3:0]  io_master_arid,
    output logic [7:0]  io_master_arlen,
    output logic [2:0]  io_master_arsize,
    output logic [1:0]  io_master_arburst,

    output logic        io_master_rready,
    input  logic        io_master_rvalid,
    input  logic [1:0]  io_master_rresp,
    input  logic [31:0] io_master_rdata,
    input  logic        io_master_rlast,
    input  logic [3:0]  io_master_rid,

    output logic        io_slave_awready,
    input  logic        io_slave_awvalid,
    input  logic [31:0] io_slave_awaddr,
    input  logic [3:0]  io_slave_awid,
    input  logic [7:0]  io_slave_awlen,
    input  logic [2:0]  io_slave_awsize,
    input  logic [1:0]  io_slave_awburst,

    output logic        io_slave_wready,
    input  logic        io_slave_wvalid,
    input  logic [31:0] io_slave_wdata,
    input  logic [3:0]  io_slave_wstrb,
    input  logic        io_slave_wlast,

    input  logic        io_slave_bready,
    output logic        io_slave_bvalid,
    output logic [1:0]  io_slave_bresp,
    output logic [3:0]  io_slave_bid,

    output logic        io_slave_arready,
    input  logic        io_slave_arvalid,
    input  logic [31:0] io_slave_araddr,
    input  logic [3:0]  io_slave_arid,
    input  logic [7:0]  io_slave_arlen,
    input  logic [2:0]  io_slave_arsize,
    input  logic [1:0]  io_slave_arburst,

    input  logic        io_slave_rready,
    output logic        io_slave_rvalid,
    output logic [1:0]  io_slave_rresp,
    output logic [31:0] io_slave_rdata,
    output logic        io_slave_rlast,
    output logic [3:0]  io_slave_rid
    /* verilator lint_on UNUSEDSIGNAL */
);

  axi_addr_t master_axi_aw;
  axi_w_t    master_axi_w;
  axi_b_t    master_axi_b;
  axi_addr_t master_axi_ar;
  axi_r_t    master_axi_r;

  // Flatten the structured master request payloads for the ysyxSoC boundary.
  always_comb begin
    io_master_awaddr  = master_axi_aw.addr;
    io_master_awid    = master_axi_aw.id;
    io_master_awlen   = master_axi_aw.len;
    io_master_awsize  = master_axi_aw.size;
    io_master_awburst = master_axi_aw.burst;

    io_master_wdata   = master_axi_w.data;
    io_master_wstrb   = master_axi_w.strb;
    io_master_wlast   = master_axi_w.last;

    io_master_araddr  = master_axi_ar.addr;
    io_master_arid    = master_axi_ar.id;
    io_master_arlen   = master_axi_ar.len;
    io_master_arsize  = master_axi_ar.size;
    io_master_arburst = master_axi_ar.burst;

    master_axi_b = '{
      resp : axi_resp_e'(io_master_bresp),
      id   : io_master_bid
    };
    master_axi_r = '{
      resp : axi_resp_e'(io_master_rresp),
      data : io_master_rdata,
      last : io_master_rlast,
      id   : io_master_rid
    };
  end

  // The current NPC has no memory-side AXI slave functionality.
  always_comb begin
    io_slave_awready = 1'b0;
    io_slave_wready  = 1'b0;
    io_slave_bvalid  = 1'b0;
    io_slave_bresp   = 2'b0;
    io_slave_bid     = 4'b0;
    io_slave_arready = 1'b0;
    io_slave_rvalid  = 1'b0;
    io_slave_rresp   = 2'b0;
    io_slave_rdata   = 32'b0;
    io_slave_rlast   = 1'b0;
    io_slave_rid     = 4'b0;
  end

  riscv32_npc_axi_core_boundary u_npc_axi_core_boundary (
      .clk_i               (clock),
      .rst_ni              (~reset),
      .master_axi_ar_o     (master_axi_ar),
      .master_axi_arvalid_o(io_master_arvalid),
      .master_axi_arready_i(io_master_arready),
      .master_axi_r_i      (master_axi_r),
      .master_axi_rvalid_i (io_master_rvalid),
      .master_axi_rready_o (io_master_rready),
      .master_axi_aw_o     (master_axi_aw),
      .master_axi_awvalid_o(io_master_awvalid),
      .master_axi_awready_i(io_master_awready),
      .master_axi_w_o      (master_axi_w),
      .master_axi_wvalid_o (io_master_wvalid),
      .master_axi_wready_i (io_master_wready),
      .master_axi_b_i      (master_axi_b),
      .master_axi_bvalid_i (io_master_bvalid),
      .master_axi_bready_o (io_master_bready)
  );

`ifdef VERILATOR
  // Simulation observability belongs at the CPU integration boundary because
  // ysyxSoCFull, rather than sim/top.sv, is now the Verilator top module.
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
    npc_get_pc_dpi = u_npc_axi_core_boundary.u_core.fetch_entry.pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = u_npc_axi_core_boundary.u_core.fetch_entry.instruction;
  endfunction

  function int npc_get_commit_valid_dpi();
    npc_get_commit_valid_dpi =
        int'(u_npc_axi_core_boundary.u_core.commit_valid);
  endfunction

  function int npc_get_commit_pc_dpi();
    npc_get_commit_pc_dpi = u_npc_axi_core_boundary.u_core.commit.pc;
  endfunction

  function int npc_get_commit_inst_dpi();
    npc_get_commit_inst_dpi =
        u_npc_axi_core_boundary.u_core.commit.instruction;
  endfunction

  function int npc_get_commit_next_pc_dpi();
    if (u_npc_axi_core_boundary.u_core.selected_redirect_req_valid &&
        u_npc_axi_core_boundary.u_core.commit_valid &&
        (u_npc_axi_core_boundary.u_core.selected_redirect_req.source_pc ==
         u_npc_axi_core_boundary.u_core.commit.pc)) begin
      npc_get_commit_next_pc_dpi =
          u_npc_axi_core_boundary.u_core.selected_redirect_req.target_pc;
    end else begin
      npc_get_commit_next_pc_dpi =
          u_npc_axi_core_boundary.u_core.commit.next_pc;
    end
  endfunction

  function int npc_get_gpr_dpi(input int index);
    if ((index <= 0) || (index >= ARCH_REG_NUM)) begin
      npc_get_gpr_dpi = '0;
    end else begin
      npc_get_gpr_dpi =
          u_npc_axi_core_boundary.u_core.u_arch_regfile.gpr_q[index];
    end
  endfunction

  always_ff @(posedge clock) begin
    if (u_npc_axi_core_boundary.u_core.commit_valid &&
        (u_npc_axi_core_boundary.u_core.commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end
`endif

endmodule
