module top
  import riscv32_pkg::*;
#(
    // TODO(AXI-TOP-LATENCY-PARAM): dmem AXI化后将DMEM参数拆成READ和WRITE两个参数，
    // 分别传给R通道和B通道延迟模型；IMEM参数对应只读R通道。
    parameter int unsigned SIM_IMEM_RESPONSE_LATENCY = 1,
    parameter int unsigned SIM_DMEM_RESPONSE_LATENCY = 1
) (
    input logic clk,
    input logic rstn
);
  localparam int unsigned REDIRECT_SOURCE_COUNT = 2;
  localparam int unsigned EXU_REDIRECT_INDEX = 0;
  localparam int unsigned COMMIT_REDIRECT_INDEX = 1;

  // TODO(AXI-TOP-WIRES): 在pkg类型完成后删除下面SimpleBus wires，声明两套彼此独立的
  // AXI4-Lite连接：
  // - IFU read-only master <-> sim_mem instruction read slave：AR/R。
  // - LSU read/write master <-> sim_mem data slave：AR/R/AW/W/B。
  // 两套link分别统一使用ifu_axi_*和lsu_axi_*前缀；不要再按目的端命名成imem_axi/dmem_axi。
  // 每个channel分别声明payload、valid和ready，不要合成一个全局req/resp握手。
  //
  // 当前sim_mem等价于双端口memory adapter，IFU和LSU可以并行握手。若未来只有一个物理
  // SRAM/外部AXI master端口，应新增axi4_lite_interconnect或memory arbiter；top负责实例化，
  // IFU/LSU内部不能互相观察对方的请求。AXI4-Lite没有ID，仲裁器必须保存响应应返回给哪个
  // master，并在不能安全跟踪时限制outstanding数量。
  imem_req_t  imem_req;
  logic       imem_req_valid;
  logic       imem_req_ready;
  imem_resp_t imem_resp;
  logic       imem_resp_valid;
  logic       imem_resp_ready;

  mem_req_t  dmem_req;
  logic      dmem_req_valid;
  logic      dmem_req_ready;
  mem_resp_t dmem_resp;
  logic      dmem_resp_valid;
  logic      dmem_resp_ready;

  fetch_entry_t fetch_entry;
  logic fetch_entry_valid;
  logic fetch_entry_ready;

  decoded_uop_t decoded_uop;
  logic decoded_uop_valid;
  logic decoded_uop_ready;

  logic [XLEN-1:0] rs1_value;
  logic [XLEN-1:0] rs2_value;
  execute_packet_t execute_packet;
  logic execute_packet_ready;

  execute_result_t exu_result;
  logic exu_result_valid;
  logic exu_result_ready;

  lsu_req_t lsu_req;
  logic lsu_req_valid;
  logic lsu_req_ready;

  writeback_result_t lsu_writeback;
  logic lsu_writeback_valid;
  logic lsu_writeback_ready;

  writeback_result_t writeback_result;
  logic writeback_result_valid;
  logic writeback_result_ready;

  commit_t commit;
  logic commit_valid;
  logic [XLEN-1:0] gpr_write_data;
  arch_reg_idx_t gpr_write_addr;
  logic gpr_write_enable;

  logic [XLEN-1:0] csr_read_data;
  logic csr_read_illegal;
  logic [XLEN-1:0] csr_mtvec;
  logic [XLEN-1:0] csr_mepc;

  logic trap_valid;
  logic [XLEN-1:0] trap_pc;
  logic [XLEN-1:0] trap_cause;
  logic [XLEN-1:0] trap_tval;
  logic mret_valid;

  redirect_req_t redirect_req[REDIRECT_SOURCE_COUNT];
  logic [REDIRECT_SOURCE_COUNT-1:0] redirect_req_valid;
  redirect_req_t selected_redirect_req;
  logic selected_redirect_req_valid;

  always_comb begin
    execute_packet             = '0;
    execute_packet.uop         = decoded_uop;
    execute_packet.rs1_value   = rs1_value;
    execute_packet.rs2_value   = rs2_value;
    execute_packet.csr_rdata   = csr_read_data;
    execute_packet.csr_illegal = csr_read_illegal;
  end

  // TODO(AXI-TOP-IFU-CONNECT): IFU端口改造完成后，将下面6条imem连接替换为AR/R连接。
  // IFU是官方允许的read-only AXI interface，所以top无需创建或tie off IFU的AW/W/B。
  // 若芯片顶层以后必须暴露一个完整read/write master端口，应在边界adapter中补齐未用通道，
  // 而不是污染IFU内部接口。
  riscv32_ifu u_ifu (
      .clk_i               (clk),
      .rst_ni              (rstn),
      .redirect_req_i      (selected_redirect_req),
      .redirect_req_valid_i(selected_redirect_req_valid),
      .imem_req_o           (imem_req),
      .imem_req_valid_o     (imem_req_valid),
      .imem_req_ready_i     (imem_req_ready),
      .imem_resp_i          (imem_resp),
      .imem_resp_valid_i    (imem_resp_valid),
      .imem_resp_ready_o    (imem_resp_ready),
      .fetch_entry_o       (fetch_entry),
      .fetch_entry_valid_o (fetch_entry_valid),
      .fetch_entry_ready_i (fetch_entry_ready)
  );

  riscv32_idu u_idu (
      .fetch_entry_i      (fetch_entry),
      .fetch_entry_valid_i(fetch_entry_valid),
      .fetch_entry_ready_o(fetch_entry_ready),
      .decoded_uop_o      (decoded_uop),
      .decoded_uop_valid_o(decoded_uop_valid),
      .decoded_uop_ready_i(decoded_uop_ready)
  );

  riscv32_arch_regfile u_arch_regfile (
      .clk_i             (clk),
      .gpr_write_data_i  (gpr_write_data),
      .gpr_write_addr_i  (gpr_write_addr),
      .gpr_write_enable_i(gpr_write_enable),
      .rs1_addr_i        (decoded_uop.rs1),
      .rs1_data_o        (rs1_value),
      .rs2_addr_i        (decoded_uop.rs2),
      .rs2_data_o        (rs2_value)
  );

  riscv32_csr_file u_csr_file (
      .clk_i             (clk),
      .rst_ni            (rstn),
      .csr_read_enable_i (decoded_uop_valid && decoded_uop.csr_ctrl.read_enable),
      .csr_read_addr_i   (decoded_uop.csr_ctrl.addr),
      .csr_read_data_o   (csr_read_data),
      .csr_read_illegal_o(csr_read_illegal),
      .csr_write_valid_i (commit_valid && commit.csr_write),
      .csr_write_addr_i  (commit.csr_addr),
      .csr_write_data_i  (commit.csr_wdata),
      .trap_valid_i      (trap_valid),
      .trap_pc_i         (trap_pc),
      .trap_cause_i      (trap_cause),
      .trap_tval_i       (trap_tval),
      .mret_valid_i      (mret_valid),
      .mtvec_o           (csr_mtvec),
      .mepc_o            (csr_mepc)
  );

  riscv32_exu u_exu (
      .execute_packet_i      (execute_packet),
      .execute_packet_valid_i(decoded_uop_valid),
      .execute_packet_ready_o(execute_packet_ready),
      .exu_result_o          (exu_result),
      .exu_result_valid_o    (exu_result_valid),
      .exu_result_ready_i    (exu_result_ready),
      .lsu_req_o             (lsu_req),
      .lsu_req_valid_o       (lsu_req_valid),
      .lsu_req_ready_i       (lsu_req_ready)
  );

  assign decoded_uop_ready = execute_packet_ready;

  // TODO(AXI-TOP-LSU-CONNECT): 将LSU的SimpleBus dmem连接替换为五通道AXI4-Lite连接。
  // 连接后逐条核对方向：AR/AW/W payload+valid从LSU到memory，ready反向；R/B
  // payload+valid从memory到LSU，ready反向。命名中保留imem/dmem前缀，避免两个AR/R
  // 通道在波形中混淆。
  riscv32_lsu u_lsu (
      .clk_i                (clk),
      .rst_ni               (rstn),
      .lsu_req_i            (lsu_req),
      .lsu_req_valid_i      (lsu_req_valid),
      .lsu_req_ready_o      (lsu_req_ready),
      .lsu_writeback_o      (lsu_writeback),
      .lsu_writeback_valid_o(lsu_writeback_valid),
      .lsu_writeback_ready_i(lsu_writeback_ready),
      .dmem_req_o           (dmem_req),
      .dmem_req_valid_o     (dmem_req_valid),
      .dmem_req_ready_i     (dmem_req_ready),
      .dmem_resp_i          (dmem_resp),
      .dmem_resp_valid_i    (dmem_resp_valid),
      .dmem_resp_ready_o    (dmem_resp_ready)
  );

  // TODO(AXI-TOP-MEM-CONNECT): sim_mem AXI slave完成后替换下面全部req/resp连接。
  // 建议把DMEM_RESPONSE_LATENCY拆成DMEM_READ_RESPONSE_LATENCY和
  // DMEM_WRITE_RESPONSE_LATENCY，使R和B能独立注入延迟。默认仍为1，先保持回归行为。
  // 参数只控制slave何时产生RVALID/BVALID，不能让VALID只脉冲一拍；下游不READY时必须保持。
  riscv32_sim_mem #(
      .IMEM_RESPONSE_LATENCY(SIM_IMEM_RESPONSE_LATENCY),
      .DMEM_RESPONSE_LATENCY(SIM_DMEM_RESPONSE_LATENCY)
  ) u_sim_mem (
      .clk_i            (clk),
      .rst_ni           (rstn),
      .imem_req_i       (imem_req),
      .imem_req_valid_i (imem_req_valid),
      .imem_req_ready_o (imem_req_ready),
      .imem_resp_o      (imem_resp),
      .imem_resp_valid_o(imem_resp_valid),
      .imem_resp_ready_i(imem_resp_ready),
      .dmem_req_i       (dmem_req),
      .dmem_req_valid_i (dmem_req_valid),
      .dmem_req_ready_o (dmem_req_ready),
      .dmem_resp_o      (dmem_resp),
      .dmem_resp_valid_o(dmem_resp_valid),
      .dmem_resp_ready_i(dmem_resp_ready)
  );

  riscv32_completion_mux u_completion_mux (
      .exu_result_i            (exu_result),
      .exu_result_valid_i      (exu_result_valid),
      .exu_result_ready_o      (exu_result_ready),
      .lsu_writeback_i         (lsu_writeback),
      .lsu_writeback_valid_i   (lsu_writeback_valid),
      .lsu_writeback_ready_o   (lsu_writeback_ready),
      .writeback_result_o      (writeback_result),
      .writeback_result_valid_o(writeback_result_valid),
      .writeback_result_ready_i(writeback_result_ready)
  );

  riscv32_commit u_commit (
      .writeback_result_i      (writeback_result),
      .writeback_result_valid_i(writeback_result_valid),
      .writeback_result_ready_o(writeback_result_ready),
      .commit_o                (commit),
      .commit_valid_o          (commit_valid),
      .gpr_write_data_o        (gpr_write_data),
      .gpr_write_addr_o        (gpr_write_addr),
      .gpr_write_enable_o      (gpr_write_enable)
  );

  riscv32_trap_controller u_trap_controller (
      .commit_i            (commit),
      .commit_valid_i      (commit_valid),
      .mtvec_i             (csr_mtvec),
      .mepc_i              (csr_mepc),
      .trap_valid_o        (trap_valid),
      .trap_pc_o           (trap_pc),
      .trap_cause_o        (trap_cause),
      .trap_tval_o         (trap_tval),
      .mret_valid_o        (mret_valid),
      .redirect_req_o      (redirect_req[COMMIT_REDIRECT_INDEX]),
      .redirect_req_valid_o(redirect_req_valid[COMMIT_REDIRECT_INDEX])
  );

  assign redirect_req[EXU_REDIRECT_INDEX] = exu_result.redirect_req;
  assign redirect_req_valid[EXU_REDIRECT_INDEX] = exu_result_valid && exu_result_ready &&
                                                   exu_result.redirect_valid;

  riscv32_redirect_arbiter #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_redirect_arbiter (
      .redirect_req_i               (redirect_req),
      .redirect_req_valid_i         (redirect_req_valid),
      .selected_redirect_req_o      (selected_redirect_req),
      .selected_redirect_req_valid_o(selected_redirect_req_valid)
  );

  // TODO(P1-TOP-CORE-SPLIT): memory channel 回归通过后，把当前可综合 CPU 模块及其连线
  // 移动到 riscv32_core.sv。riscv32_core 只暴露 clock/reset、imem/dmem channel
  // 和 commit/debug event；top 只实例化 core、riscv32_sim_mem 与 riscv32_sim_debug。
  // 下面的 DPI debug hooks 移入 riscv32_sim_debug，不能进入 riscv32_core。
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
    npc_get_pc_dpi = fetch_entry.pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = fetch_entry.instruction;
  endfunction

  function int npc_get_commit_valid_dpi();
    npc_get_commit_valid_dpi = int'(commit_valid);
  endfunction

  function int npc_get_commit_pc_dpi();
    npc_get_commit_pc_dpi = commit.pc;
  endfunction

  function int npc_get_commit_inst_dpi();
    npc_get_commit_inst_dpi = commit.instruction;
  endfunction

  function int npc_get_commit_next_pc_dpi();
    npc_get_commit_next_pc_dpi = commit.next_pc;
  endfunction

  function int npc_get_gpr_dpi(input int index);
    if ((index <= 0) || (index >= ARCH_REG_NUM)) begin
      npc_get_gpr_dpi = '0;
    end else begin
      npc_get_gpr_dpi = u_arch_regfile.gpr_q[index];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (commit_valid && (commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end

endmodule
