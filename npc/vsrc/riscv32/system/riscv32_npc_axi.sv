// ysyxSoC CPU boundary. The external port names and widths must match
// ysyxSoC/spec/cpu-interface.md exactly; structured payloads remain internal.
module riscv32_npc_axi
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter logic [XLEN-1:0] RESET_PC = RESET_VECTOR
) (
    input logic clock,
    input logic reset,

    // External interrupts remain unsupported; the core-local timer interrupt is wired internally.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic io_interrupt,

    input  logic        io_master_awready,
    output logic        io_master_awvalid,
    output logic [31:0] io_master_awaddr,
    output logic [ 3:0] io_master_awid,
    output logic [ 7:0] io_master_awlen,
    output logic [ 2:0] io_master_awsize,
    output logic [ 1:0] io_master_awburst,

    input  logic        io_master_wready,
    output logic        io_master_wvalid,
    output logic [31:0] io_master_wdata,
    output logic [ 3:0] io_master_wstrb,
    output logic        io_master_wlast,

    output logic       io_master_bready,
    input  logic       io_master_bvalid,
    input  logic [1:0] io_master_bresp,
    input  logic [3:0] io_master_bid,

    input  logic        io_master_arready,
    output logic        io_master_arvalid,
    output logic [31:0] io_master_araddr,
    output logic [ 3:0] io_master_arid,
    output logic [ 7:0] io_master_arlen,
    output logic [ 2:0] io_master_arsize,
    output logic [ 1:0] io_master_arburst,

    output logic        io_master_rready,
    input  logic        io_master_rvalid,
    input  logic [ 1:0] io_master_rresp,
    input  logic [31:0] io_master_rdata,
    input  logic        io_master_rlast,
    input  logic [ 3:0] io_master_rid,

    output logic        io_slave_awready,
    input  logic        io_slave_awvalid,
    input  logic [31:0] io_slave_awaddr,
    input  logic [ 3:0] io_slave_awid,
    input  logic [ 7:0] io_slave_awlen,
    input  logic [ 2:0] io_slave_awsize,
    input  logic [ 1:0] io_slave_awburst,

    output logic        io_slave_wready,
    input  logic        io_slave_wvalid,
    input  logic [31:0] io_slave_wdata,
    input  logic [ 3:0] io_slave_wstrb,
    input  logic        io_slave_wlast,

    input  logic       io_slave_bready,
    output logic       io_slave_bvalid,
    output logic [1:0] io_slave_bresp,
    output logic [3:0] io_slave_bid,

    output logic        io_slave_arready,
    input  logic        io_slave_arvalid,
    input  logic [31:0] io_slave_araddr,
    input  logic [ 3:0] io_slave_arid,
    input  logic [ 7:0] io_slave_arlen,
    input  logic [ 2:0] io_slave_arsize,
    input  logic [ 1:0] io_slave_arburst,

    input  logic        io_slave_rready,
    output logic        io_slave_rvalid,
    output logic [ 1:0] io_slave_rresp,
    output logic [31:0] io_slave_rdata,
    output logic        io_slave_rlast,
    output logic [ 3:0] io_slave_rid
    /* verilator lint_on UNUSEDSIGNAL */
);

  axi4_manager_to_target_t external_axi4_manager;
  axi4_target_to_manager_t external_axi4_manager_response;

  // ysyxSoC uses flat AXI4 pins. This block only maps those pins to the
  // internal typed channel bundles; it does not alter AXI4 transaction timing.
  always_comb begin
    io_master_awvalid = external_axi4_manager.aw_valid;
    io_master_awaddr  = external_axi4_manager.aw.addr;
    io_master_awid    = external_axi4_manager.aw.id;
    io_master_awlen   = external_axi4_manager.aw.len;
    io_master_awsize  = external_axi4_manager.aw.size;
    io_master_awburst = external_axi4_manager.aw.burst;

    io_master_wvalid = external_axi4_manager.w_valid;
    io_master_wdata  = external_axi4_manager.w.data;
    io_master_wstrb  = external_axi4_manager.w.strb;
    io_master_wlast  = external_axi4_manager.w.last;

    io_master_bready = external_axi4_manager.b_ready;

    io_master_arvalid = external_axi4_manager.ar_valid;
    io_master_araddr  = external_axi4_manager.ar.addr;
    io_master_arid    = external_axi4_manager.ar.id;
    io_master_arlen   = external_axi4_manager.ar.len;
    io_master_arsize  = external_axi4_manager.ar.size;
    io_master_arburst = external_axi4_manager.ar.burst;

    io_master_rready = external_axi4_manager.r_ready;

    external_axi4_manager_response          = '0;
    external_axi4_manager_response.aw_ready = io_master_awready;
    external_axi4_manager_response.w_ready  = io_master_wready;
    external_axi4_manager_response.b_valid  = io_master_bvalid;
    external_axi4_manager_response.b.id     = io_master_bid;
    external_axi4_manager_response.b.resp   = axi4_resp_e'(io_master_bresp);
    external_axi4_manager_response.ar_ready = io_master_arready;
    external_axi4_manager_response.r_valid  = io_master_rvalid;
    external_axi4_manager_response.r.id     = io_master_rid;
    external_axi4_manager_response.r.data   = io_master_rdata;
    external_axi4_manager_response.r.resp   = axi4_resp_e'(io_master_rresp);
    external_axi4_manager_response.r.last   = io_master_rlast;
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

  riscv32_npc_system #(
      .RESET_PC(RESET_PC)
  ) u_npc_system (
      .clk_i                  (clock),
      .rst_ni                 (~reset),
      .external_axi4_manager_o(external_axi4_manager),
      .external_axi4_manager_i(external_axi4_manager_response)
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
    npc_get_pc_dpi = u_npc_system.u_core.idu_fetch_entry.pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = u_npc_system.u_core.idu_fetch_entry.instruction;
  endfunction

  function int npc_get_commit_valid_dpi();
    npc_get_commit_valid_dpi = int'(u_npc_system.u_core.commit_valid);
  endfunction

  function int npc_get_commit_pc_dpi();
    npc_get_commit_pc_dpi = u_npc_system.u_core.commit.pc;
  endfunction

  function int npc_get_commit_inst_dpi();
    npc_get_commit_inst_dpi = u_npc_system.u_core.commit.instruction;
  endfunction

  function int npc_get_commit_next_pc_dpi();
    if (u_npc_system.u_core.selected_redirect_req_valid &&
        u_npc_system.u_core.commit_valid &&
        (u_npc_system.u_core.selected_redirect_req.source_pc ==
         u_npc_system.u_core.commit.pc)) begin
      npc_get_commit_next_pc_dpi = u_npc_system.u_core.selected_redirect_req.target_pc;
    end else begin
      npc_get_commit_next_pc_dpi = u_npc_system.u_core.commit.next_pc;
    end
  endfunction

  function int npc_get_gpr_dpi(input int index);
    if ((index <= 0) || (index >= ARCH_REG_NUM)) begin
      npc_get_gpr_dpi = '0;
    end else begin
      npc_get_gpr_dpi = u_npc_system.u_core.u_arch_regfile.gpr_q[index];
    end
  endfunction

  always_ff @(posedge clock) begin
    if (u_npc_system.u_core.commit_valid &&
        (u_npc_system.u_core.commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end
`endif

endmodule
