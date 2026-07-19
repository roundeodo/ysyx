// Simulation shell. Synthesizable CPU, arbitration, and address routing remain
// separate from the simulation-only memory, UART, and debug hooks instantiated
// here.
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
  localparam int unsigned AXI_SLAVE_COUNT          = 3;
  localparam int unsigned UART_SLAVE_INDEX         = 0;
  localparam int unsigned DPI_PLATFORM_SLAVE_INDEX = 1;
  localparam int unsigned CLINT_SLAVE_INDEX        = 2;

  localparam logic [XLEN-1:0] AXI_SLAVE_BASE_ADDR_ARRAY[AXI_SLAVE_COUNT] =
      '{32'h1000_0000, 32'h8000_0000, 32'ha000_0000};
  localparam logic [XLEN-1:0] AXI_SLAVE_ADDR_MASK_ARRAY[AXI_SLAVE_COUNT] =
      '{32'hffff_f000, 32'hf800_0000, 32'hffff_0000};

  // The DPI platform region now covers only the 128 MiB PMEM window. CLINT owns
  // the 0xa000_0000 timer window, avoiding overlapping xbar address matches.

  axi_lite_addr_t slave_axi_ar_array     [AXI_SLAVE_COUNT];
  logic           slave_axi_arvalid_array[AXI_SLAVE_COUNT];
  logic           slave_axi_arready_array[AXI_SLAVE_COUNT];
  axi_lite_r_t    slave_axi_r_array      [AXI_SLAVE_COUNT];
  logic           slave_axi_rvalid_array [AXI_SLAVE_COUNT];
  logic           slave_axi_rready_array [AXI_SLAVE_COUNT];

  axi_lite_addr_t slave_axi_aw_array     [AXI_SLAVE_COUNT];
  logic           slave_axi_awvalid_array[AXI_SLAVE_COUNT];
  logic           slave_axi_awready_array[AXI_SLAVE_COUNT];
  axi_lite_w_t    slave_axi_w_array      [AXI_SLAVE_COUNT];
  logic           slave_axi_wvalid_array [AXI_SLAVE_COUNT];
  logic           slave_axi_wready_array [AXI_SLAVE_COUNT];
  axi_lite_b_t    slave_axi_b_array      [AXI_SLAVE_COUNT];
  logic           slave_axi_bvalid_array [AXI_SLAVE_COUNT];
  logic           slave_axi_bready_array [AXI_SLAVE_COUNT];

  axi_lite_addr_t npc_axi_ar;
  logic           npc_axi_arvalid;
  logic           npc_axi_arready;
  axi_lite_r_t    npc_axi_r;
  logic           npc_axi_rvalid;
  logic           npc_axi_rready;

  axi_lite_addr_t npc_axi_aw;
  logic           npc_axi_awvalid;
  logic           npc_axi_awready;
  axi_lite_w_t    npc_axi_w;
  logic           npc_axi_wvalid;
  logic           npc_axi_wready;
  axi_lite_b_t    npc_axi_b;
  logic           npc_axi_bvalid;
  logic           npc_axi_bready;

  riscv32_npc_axi_lite u_npc_axi_lite (
      .clk_i            (clk),
      .rst_ni           (rstn),
      .mem_axi_ar_o     (npc_axi_ar),
      .mem_axi_arvalid_o(npc_axi_arvalid),
      .mem_axi_arready_i(npc_axi_arready),
      .mem_axi_r_i      (npc_axi_r),
      .mem_axi_rvalid_i (npc_axi_rvalid),
      .mem_axi_rready_o (npc_axi_rready),
      .mem_axi_aw_o     (npc_axi_aw),
      .mem_axi_awvalid_o(npc_axi_awvalid),
      .mem_axi_awready_i(npc_axi_awready),
      .mem_axi_w_o      (npc_axi_w),
      .mem_axi_wvalid_o (npc_axi_wvalid),
      .mem_axi_wready_i (npc_axi_wready),
      .mem_axi_b_i      (npc_axi_b),
      .mem_axi_bvalid_i (npc_axi_bvalid),
      .mem_axi_bready_o (npc_axi_bready)
  );

  riscv32_axi_lite_xbar #(
      .SLAVE_COUNT    (AXI_SLAVE_COUNT),
      .SLAVE_BASE_ADDR(AXI_SLAVE_BASE_ADDR_ARRAY),
      .SLAVE_ADDR_MASK(AXI_SLAVE_ADDR_MASK_ARRAY)
  ) u_axi_lite_xbar (
      .clk_i              (clk),
      .rst_ni             (rstn),
      .npc_axi_ar_i       (npc_axi_ar),
      .npc_axi_arvalid_i  (npc_axi_arvalid),
      .npc_axi_arready_o  (npc_axi_arready),
      .npc_axi_r_o        (npc_axi_r),
      .npc_axi_rvalid_o   (npc_axi_rvalid),
      .npc_axi_rready_i   (npc_axi_rready),
      .npc_axi_aw_i       (npc_axi_aw),
      .npc_axi_awvalid_i  (npc_axi_awvalid),
      .npc_axi_awready_o  (npc_axi_awready),
      .npc_axi_w_i        (npc_axi_w),
      .npc_axi_wvalid_i   (npc_axi_wvalid),
      .npc_axi_wready_o   (npc_axi_wready),
      .npc_axi_b_o        (npc_axi_b),
      .npc_axi_bvalid_o   (npc_axi_bvalid),
      .npc_axi_bready_i   (npc_axi_bready),
      .slave_axi_ar_o     (slave_axi_ar_array),
      .slave_axi_arvalid_o(slave_axi_arvalid_array),
      .slave_axi_arready_i(slave_axi_arready_array),
      .slave_axi_r_i      (slave_axi_r_array),
      .slave_axi_rvalid_i (slave_axi_rvalid_array),
      .slave_axi_rready_o (slave_axi_rready_array),
      .slave_axi_aw_o     (slave_axi_aw_array),
      .slave_axi_awvalid_o(slave_axi_awvalid_array),
      .slave_axi_awready_i(slave_axi_awready_array),
      .slave_axi_w_o      (slave_axi_w_array),
      .slave_axi_wvalid_o (slave_axi_wvalid_array),
      .slave_axi_wready_i (slave_axi_wready_array),
      .slave_axi_b_i      (slave_axi_b_array),
      .slave_axi_bvalid_i (slave_axi_bvalid_array),
      .slave_axi_bready_o (slave_axi_bready_array)
  );

  riscv32_axi_lite_uart_sim u_uart_sim (
      .clk_i             (clk),
      .rst_ni            (rstn),
      .uart_axi_ar_i     (slave_axi_ar_array[UART_SLAVE_INDEX]),
      .uart_axi_arvalid_i(slave_axi_arvalid_array[UART_SLAVE_INDEX]),
      .uart_axi_arready_o(slave_axi_arready_array[UART_SLAVE_INDEX]),
      .uart_axi_r_o      (slave_axi_r_array[UART_SLAVE_INDEX]),
      .uart_axi_rvalid_o (slave_axi_rvalid_array[UART_SLAVE_INDEX]),
      .uart_axi_rready_i (slave_axi_rready_array[UART_SLAVE_INDEX]),
      .uart_axi_aw_i     (slave_axi_aw_array[UART_SLAVE_INDEX]),
      .uart_axi_awvalid_i(slave_axi_awvalid_array[UART_SLAVE_INDEX]),
      .uart_axi_awready_o(slave_axi_awready_array[UART_SLAVE_INDEX]),
      .uart_axi_w_i      (slave_axi_w_array[UART_SLAVE_INDEX]),
      .uart_axi_wvalid_i (slave_axi_wvalid_array[UART_SLAVE_INDEX]),
      .uart_axi_wready_o (slave_axi_wready_array[UART_SLAVE_INDEX]),
      .uart_axi_b_o      (slave_axi_b_array[UART_SLAVE_INDEX]),
      .uart_axi_bvalid_o (slave_axi_bvalid_array[UART_SLAVE_INDEX]),
      .uart_axi_bready_i (slave_axi_bready_array[UART_SLAVE_INDEX])
  );

  riscv32_sim_mem #(
      .IFU_READ_LATENCY  (SIM_IFU_READ_LATENCY),
      .LSU_READ_LATENCY  (SIM_LSU_READ_LATENCY),
      .LSU_WRITE_LATENCY (SIM_LSU_WRITE_LATENCY),
      .RANDOM_LATENCY_MAX(SIM_RANDOM_LATENCY_MAX)
  ) u_sim_mem (
      .clk_i            (clk),
      .rst_ni           (rstn),
      .mem_axi_ar_i     (slave_axi_ar_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_arvalid_i(slave_axi_arvalid_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_arready_o(slave_axi_arready_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_r_o      (slave_axi_r_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_rvalid_o (slave_axi_rvalid_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_rready_i (slave_axi_rready_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_aw_i     (slave_axi_aw_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_awvalid_i(slave_axi_awvalid_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_awready_o(slave_axi_awready_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_w_i      (slave_axi_w_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_wvalid_i (slave_axi_wvalid_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_wready_o (slave_axi_wready_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_b_o      (slave_axi_b_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_bvalid_o (slave_axi_bvalid_array[DPI_PLATFORM_SLAVE_INDEX]),
      .mem_axi_bready_i (slave_axi_bready_array[DPI_PLATFORM_SLAVE_INDEX])
  );

  riscv32_axi_lite_clint u_clint (
      .clk_i              (clk),
      .rst_ni             (rstn),
      .clint_axi_ar_i     (slave_axi_ar_array[CLINT_SLAVE_INDEX]),
      .clint_axi_arvalid_i(slave_axi_arvalid_array[CLINT_SLAVE_INDEX]),
      .clint_axi_arready_o(slave_axi_arready_array[CLINT_SLAVE_INDEX]),
      .clint_axi_r_o      (slave_axi_r_array[CLINT_SLAVE_INDEX]),
      .clint_axi_rvalid_o (slave_axi_rvalid_array[CLINT_SLAVE_INDEX]),
      .clint_axi_rready_i (slave_axi_rready_array[CLINT_SLAVE_INDEX]),
      .clint_axi_aw_i     (slave_axi_aw_array[CLINT_SLAVE_INDEX]),
      .clint_axi_awvalid_i(slave_axi_awvalid_array[CLINT_SLAVE_INDEX]),
      .clint_axi_awready_o(slave_axi_awready_array[CLINT_SLAVE_INDEX]),
      .clint_axi_w_i      (slave_axi_w_array[CLINT_SLAVE_INDEX]),
      .clint_axi_wvalid_i (slave_axi_wvalid_array[CLINT_SLAVE_INDEX]),
      .clint_axi_wready_o (slave_axi_wready_array[CLINT_SLAVE_INDEX]),
      .clint_axi_b_o      (slave_axi_b_array[CLINT_SLAVE_INDEX]),
      .clint_axi_bvalid_o (slave_axi_bvalid_array[CLINT_SLAVE_INDEX]),
      .clint_axi_bready_i (slave_axi_bready_array[CLINT_SLAVE_INDEX])
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
