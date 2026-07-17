module top
  import riscv32_pkg::*;
(
    input logic clk,
    input logic rstn
);
  localparam int unsigned REDIRECT_SOURCE_COUNT = 2;
  localparam int unsigned EXU_REDIRECT_INDEX = 0;
  localparam int unsigned COMMIT_REDIRECT_INDEX = 1;

  // TODO(BUS-TOP-MEM-WIRES): 在这里声明两组独立的 instruction/data memory channel：
  //   imem_req_t/imem_resp_t + 各自 req_valid/req_ready/resp_valid/resp_ready；
  //   mem_req_t/mem_resp_t   + 各自 req_valid/req_ready/resp_valid/resp_ready。
  // IFU 和 LSU 不应共享一组散线。Harvard 双通道允许未来 I-cache/D-cache 独立等待，
  // 到 P3 再由 core 外部的 interconnect/arbiter 映射到共享 SoC 总线。
  fetch_entry_t                                  fetch_entry;
  logic                                          fetch_valid;
  logic                                          fetch_ready;

  decoded_uop_t                                  decoded_uop;
  logic                                          decoded_valid;
  logic                                          decoded_ready;

  logic              [                 XLEN-1:0] rs1_value;
  logic              [                 XLEN-1:0] rs2_value;
  execute_packet_t                               execute_packet;
  logic                                          execute_ready;

  execute_result_t                               exu_result;
  logic                                          exu_result_valid;
  logic                                          exu_result_ready;

  lsu_req_t                                      lsu_req;
  logic                                          lsu_req_valid;
  logic                                          lsu_req_ready;

  writeback_result_t                             lsu_writeback;
  logic                                          lsu_writeback_valid;
  logic                                          lsu_writeback_ready;

  writeback_result_t                             writeback_result;
  logic                                          writeback_valid;
  logic                                          writeback_ready;

  commit_t                                       commit;
  logic                                          commit_valid;
  logic              [                 XLEN-1:0] gpr_write_data;
  arch_reg_idx_t                                 gpr_write_addr;
  logic                                          gpr_write_enable;

  logic              [                 XLEN-1:0] csr_read_data;
  logic                                          csr_read_illegal;
  logic              [                 XLEN-1:0] csr_mtvec;
  logic              [                 XLEN-1:0] csr_mepc;

  logic                                          trap_valid;
  logic              [                 XLEN-1:0] trap_pc;
  logic              [                 XLEN-1:0] trap_cause;
  logic              [                 XLEN-1:0] trap_tval;
  logic                                          mret_valid;

  redirect_req_t                                 redirect_req        [REDIRECT_SOURCE_COUNT];
  logic              [REDIRECT_SOURCE_COUNT-1:0] redirect_req_valid;
  redirect_req_t                                 selected_redirect_req;
  logic                                          selected_redirect_req_valid;

  always_comb begin
    execute_packet             = '0;
    execute_packet.uop         = decoded_uop;
    execute_packet.rs1_value   = rs1_value;
    execute_packet.rs2_value   = rs2_value;
    execute_packet.csr_rdata   = csr_read_data;
    execute_packet.csr_illegal = csr_read_illegal;
  end

  riscv32_ifu u_ifu (
      .clk_i           (clk),
      .rst_ni          (rstn),
      .redirect_req_i      (selected_redirect_req),
      .redirect_req_valid_i(selected_redirect_req_valid),
      // TODO(BUS-TOP-IFU-MEM): 在这里连接上面声明的 imem request/response 六个信号。
      // imem request/response 六个信号。不要把 pmem_read 或地址解码逻辑放进 top。
      .fetch_entry_o   (fetch_entry),
      .fetch_valid_o   (fetch_valid),
      .fetch_ready_i   (fetch_ready)
  );

  riscv32_idu u_idu (
      .fetch_entry_i  (fetch_entry),
      .fetch_valid_i  (fetch_valid),
      .fetch_ready_o  (fetch_ready),
      .decoded_uop_o  (decoded_uop),
      .decoded_valid_o(decoded_valid),
      .decoded_ready_i(decoded_ready)
  );

  riscv32_arch_regfile u_arch_regfile (
      .clk_i         (clk),
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
      .csr_read_enable_i (decoded_valid && decoded_uop.csr_ctrl.read_enable),
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
      .execute_packet_i  (execute_packet),
      .execute_valid_i   (decoded_valid),
      .execute_ready_o   (execute_ready),
      .exu_result_o      (exu_result),
      .exu_result_valid_o(exu_result_valid),
      .exu_result_ready_i(exu_result_ready),
      .lsu_req_o         (lsu_req),
      .lsu_req_valid_o   (lsu_req_valid),
      .lsu_req_ready_i   (lsu_req_ready)
  );

  assign decoded_ready = execute_ready;

  riscv32_lsu u_lsu (
      .clk_i             (clk),
      // TODO(BUS-TOP-LSU-RESET): LSU 有状态后在这里连接 .rst_ni(rstn)。
      .lsu_req_i            (lsu_req),
      .lsu_req_valid_i      (lsu_req_valid),
      .lsu_req_ready_o      (lsu_req_ready),
      .lsu_writeback_o      (lsu_writeback),
      .lsu_writeback_valid_o(lsu_writeback_valid),
      .lsu_writeback_ready_i(lsu_writeback_ready)
      // TODO(BUS-TOP-LSU-MEM): 在这里连接 dmem request/response 六个信号。
      // request/response 六个信号。添加第一个连接前给上一行补逗号。
  );

  // TODO(BUS-TOP-SIM-MEM): 在本位置实例化 riscv32_sim_mem，同时连接 imem 与 dmem
  // 完整握手通道。DPI 只能存在于该 simulation slave；top 不得自行调用 pmem。
  // IFU/LSU/core 的端口不能因固定一拍、随机延迟或未来 cache/bus adapter 再次变化。

  riscv32_completion_mux u_completion_mux (
      .exu_result_i          (exu_result),
      .exu_result_valid_i    (exu_result_valid),
      .exu_result_ready_o    (exu_result_ready),
      .lsu_writeback_i       (lsu_writeback),
      .lsu_writeback_valid_i (lsu_writeback_valid),
      .lsu_writeback_ready_o (lsu_writeback_ready),
      .writeback_result_o    (writeback_result),
      .writeback_valid_o     (writeback_valid),
      .writeback_ready_i     (writeback_ready)
  );

  riscv32_commit u_commit (
      .writeback_result_i(writeback_result),
      .writeback_valid_i (writeback_valid),
      .writeback_ready_o (writeback_ready),
      .commit_o          (commit),
      .commit_valid_o    (commit_valid),
      .gpr_write_data_o  (gpr_write_data),
      .gpr_write_addr_o  (gpr_write_addr),
      .gpr_write_enable_o(gpr_write_enable)
  );

  riscv32_trap_controller u_trap_controller (
      .commit_i        (commit),
      .commit_valid_i  (commit_valid),
      .mtvec_i         (csr_mtvec),
      .mepc_i          (csr_mepc),
      .trap_valid_o    (trap_valid),
      .trap_pc_o       (trap_pc),
      .trap_cause_o    (trap_cause),
      .trap_tval_o     (trap_tval),
      .mret_valid_o    (mret_valid),
      .redirect_req_o      (redirect_req[COMMIT_REDIRECT_INDEX]),
      .redirect_req_valid_o(redirect_req_valid[COMMIT_REDIRECT_INDEX])
  );

  assign redirect_req[EXU_REDIRECT_INDEX] = exu_result.redirect_req;
  assign redirect_req_valid[EXU_REDIRECT_INDEX] = exu_result_valid && exu_result_ready &&
                                                   exu_result.redirect_valid;

  riscv32_redirect_arbiter #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_redirect_arbiter (
      .redirect_req_i             (redirect_req),
      .redirect_req_valid_i       (redirect_req_valid),
      .selected_redirect_o        (selected_redirect_req),
      .selected_redirect_valid_o  (selected_redirect_req_valid)
  );

  // TODO(P1-TOP-CORE-SPLIT): memory channel 回归通过后，把第 62-192 行的可综合 CPU
  // 结构移动到 riscv32_core.sv。riscv32_core 只暴露 clock/reset、imem/dmem channel
  // 和 commit/debug event；top 只实例化 core、riscv32_sim_mem 与 riscv32_sim_debug。
  // 下面的 DPI debug hooks 移入 riscv32_sim_debug，不能进入 riscv32_core。
  import "DPI-C" context function void npc_set_dpi_scope();
  import "DPI-C" context function void ebreak_halt();

  initial begin
    npc_set_dpi_scope();
  end

  export "DPI-C" function npc_get_pc_dpi;
  export "DPI-C" function npc_get_inst_dpi;

  // TODO(BUS-TOP-COMMIT-DPI): 多周期后 fetch 并不等于执行完成。在本位置新增只读 DPI
  // 导出，让软件能在 clk=0、posedge 之前采样 commit_valid、commit.pc、
  // commit.instruction 和 commit.next_pc。不要从 IFU fetch_entry 推断退休事件。
  // 建议接口：npc_get_commit_valid_dpi/pc_dpi/inst_dpi/next_pc_dpi。

  function int npc_get_pc_dpi();
    npc_get_pc_dpi = fetch_entry.pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = fetch_entry.instruction;
  endfunction

  always_ff @(posedge clk) begin
    if (rstn && commit_valid && (commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end

endmodule
