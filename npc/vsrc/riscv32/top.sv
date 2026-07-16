module top
  import riscv32_pkg::*;
#(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 5
) (
    input logic clk,
    input logic rstn
);
  // TODO(HP-TOP-1): 将 CPU 本体从仿真顶层中拆出为 riscv32_core。
  // 本文件最终只例化 Core、riscv32_sim_mem 和 riscv32_sim_debug；Core 内只保留
  // CPU 模块及结构连接，不允许出现 DPI import/export、ebreak_halt 或仿真内存调用。
  // 先不要立刻新建 Core：完成 HP-IDU 和 HP-TOP-2/3 后再移动现有实例，减少同时断线。

  // top is only the structural connection layer. It should pass decoded control
  // and execution result records between modules, not repeat ISA decode here.
  decode_ctrl_t w_decode_ctrl;

  // C2 has no commit/trap stage yet, so these control metadata bits are
  // intentionally produced by IDU but not consumed by top.
  // Future pipeline/OoO designs should carry them to commit/retire.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ctrl_metadata;
  assign unused_ctrl_metadata = ^{w_decode_ctrl.valid, w_decode_ctrl.illegal_instr, w_decode_ctrl.exception_cause};
  /* verilator lint_on UNUSEDSIGNAL */

  // TODO(HP-TOP-2): 用 fetch_packet_t + 独立 valid/ready 替换下面 IFU/IDU 散线。
  // 第一阶段可先声明 `fetch_packet_t fetch_packet;`，把 IFU 的 pc/instruction 打包后
  // 直接送 IDU；加入流水寄存器时再增加 fetch_valid/fetch_ready。
  // IDU 接通后删除 w_opcode、w_funct_*、w_imm_*、w_rd/rs*_addr 这些顶层散线。
  // IFU to IDU
  logic [DATA_WIDTH-1:0] w_pc;
  logic [DATA_WIDTH-1:0] w_instruction;

  // IDU to Ctrl & EXU
  logic [6:0] w_opcode;
  logic [2:0] w_funct_3;
  logic [6:0] w_funct_7;
  logic [4:0] w_rd_addr;
  logic [4:0] w_rs1_addr;
  logic [4:0] w_rs2_addr;
  logic [31:0] w_imm_I, w_imm_S, w_imm_U;
  logic        [          11:0] w_funct_12;
  logic        [          31:0] w_imm_B;
  logic        [          31:0] w_imm_J;

  // RF to EXU
  logic        [DATA_WIDTH-1:0] w_rs1_data;
  logic        [DATA_WIDTH-1:0] w_rs2_data;

  // EXU to LSU & IFU
  // ex_result_t is the single execution-result record produced by EXU.
  // Keep top as a connection layer: pass fields or the whole record forward,
  // but do not recreate old w_ex_* scattered wires.
  ex_result_t                   w_ex_result;

  // LSU to WBU
  // lsu_result_t is the LSU completion record consumed by WBU.
  // Future bypass, writeback arbitration, and ROB completion should consume
  // this record instead of reconstructing result metadata from top-level wires.
  lsu_result_t                  w_lsu_result;

  // WBU to RegFile
  logic        [DATA_WIDTH-1:0] w_wbu_wdata;
  logic        [           4:0] w_wbu_waddr;
  logic                         w_wbu_wen;

  // imm Mux to EXU
  logic        [DATA_WIDTH-1:0] w_imm_final;

  // CSR related
  logic        [          31:0] w_csr_rdata;
  logic        [          31:0] w_csr_mtvec;
  logic        [          31:0] w_csr_mepc;
  logic                         w_csr_illegal;

  /* verilator lint_off UNUSEDSIGNAL */
  logic                         unused_csr_status;
  assign unused_csr_status = w_csr_illegal;
  /* verilator lint_on UNUSEDSIGNAL */

  logic                         w_redirect_valid;
  logic        [          31:0] w_redirect_pc;


  // TODO(HP-TOP-3): 完成 HP-IDU-3 后删除整个 immediate mux。
  // EXU/issue request 应直接使用 decoded_uop_t.imm；top 不应理解 IMM_I/S/B/U/J。
  always_comb begin
    // Immediate mux uses IDU output, not opcode decode in top.
    // This keeps ISA decode centralized in IDU and lets future ID/EX
    // or dispatch-stage uop control carry imm_sel as metadata.
    case (w_decode_ctrl.imm_sel)
      IMM_NONE: w_imm_final = 32'b0;
      IMM_I:    w_imm_final = w_imm_I;
      IMM_S:    w_imm_final = w_imm_S;
      IMM_B:    w_imm_final = w_imm_B;
      IMM_U:    w_imm_final = w_imm_U;
      IMM_J:    w_imm_final = w_imm_J;
      default:  w_imm_final = 32'b0;
    endcase
  end

  // module instatiation
  riscv32_RDU #(
      .DATA_WIDTH(DATA_WIDTH)
  ) u_redirect_arbiter (
      .i_ex_redirect_valid(w_ex_result.redirect_valid),
      .i_ex_redirect_pc(w_ex_result.redirect_pc),

      .i_trap_redirect_valid(w_decode_ctrl.ecall_en),
      .i_trap_vector_pc(w_csr_mtvec),

      .i_mret_redirect_valid(w_decode_ctrl.mret_en),
      .i_mret_pc(w_csr_mepc),

      .o_redirect_valid(w_redirect_valid),
      .o_redirect_pc(w_redirect_pc)
  );

  riscv32_IFU #(
      .DATA_WIDTH(DATA_WIDTH),
      .PC_START  (32'h80000000)
  ) u_ifu (
      .clk(clk),
      .rstn(rstn),
      // IFU consumes redirect, not a jump-specific signal. This same interface
      // can later carry branch recovery, exception, mret, or debug redirects.
      .i_if_redirect_valid(w_redirect_valid),
      .i_if_redirect_pc(w_redirect_pc),
      .o_if_pc(w_pc),
      .o_if_instruction(w_instruction)
  );

  // TODO(HP-TOP-4): 旧的 field-extractor IDU 已删除，其职责必须合并进下面唯一的 u_idu。
  // 完成 HP-IDU-1/2/3 后，把下面 u_idu 的 legacy raw-field 端口改成：
  //   .fetch_packet_i(fetch_packet),
  //   .decoded_uop_o (decoded_uop)
  // 随后删除全部 w_opcode/w_funct_*/w_imm_*/w_*_addr 散线；top 不再提取指令字段。
  // 当前 raw-field 信号因旧模块已删除而未驱动，这是该 TODO 尚未完成的直接检查点。
  riscv32_idu u_idu (
      .i_idu_opcode(w_opcode),

      .i_idu_funct_3 (w_funct_3),
      .i_idu_funct_7 (w_funct_7),
      .i_idu_funct_12(w_funct_12),

      .i_idu_rd_addr (w_rd_addr),
      .i_idu_rs1_addr(w_rs1_addr),
      .i_idu_rs2_addr(w_rs2_addr),

      .o_idu_ctrl(w_decode_ctrl)
  );

  // TODO(HP-TOP-4B): IDU 输出 decoded_uop_t 后，在这里建立后端入口，而不是继续直连 RF->EXU。
  // 推荐实现顺序：先加一项 Decode/Execute 寄存器和 valid/ready；再替换为 riscv32_rename and riscv32_dispatch；
  // 随后加入 RAT/FreeList/ROB allocation 和按 fu_type 分发的 riscv32_issue_queue。
  // 多发射时这些端口改成数组 [ISSUE_WIDTH-1:0]，不要复制多套 top 散线。
  RegisterFile #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) u_arch_regfile (
      .clk(clk),
      .i_RF_wdata(w_wbu_wdata),
      .i_RF_waddr(w_wbu_waddr),
      .i_RF_wen(w_wbu_wen),
      .i_RF_raddr1(w_rs1_addr),
      .o_RF_rdata1(w_rs1_data),
      .i_RF_raddr2(w_rs2_addr),
      .o_RF_rdata2(w_rs2_data)
  );

  // TODO(HP-TOP-5): CSR 不能长期直接消费当前 Decode 指令的写使能和 rs1_data。
  // 建立 riscv32_commit/riscv32_trap_ctrl 后，把这里改成 commit_csr_write 和 commit_trap 两类请求；
  // CSR read/execute 可以提前进行，但 CSR architectural state 只能在 ROB 头部提交时修改。
  riscv32_CSR #(
      .ADDR_WIDTH(12),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_csr_file (
      .clk(clk),
      .rst(~rstn),

      .i_csr_ren (w_decode_ctrl.csr_ren),
      .i_csr_wren(w_decode_ctrl.csr_wren),
      .i_csr_addr(w_funct_12),
      .i_csr_op  (w_decode_ctrl.csr_op),
      .i_csr_src (w_rs1_data),

      .i_trap_valid (w_decode_ctrl.ecall_en),
      .i_trap_mepc  (w_pc),
      .i_trap_mcause(32'd11),

      .o_csr_mtvec(w_csr_mtvec),
      .o_csr_mepc (w_csr_mepc),

      .o_csr_rdata  (w_csr_rdata),
      .o_csr_illegal(w_csr_illegal)
  );

  // TODO(HP-TOP-6): 用 execute request channel 替换 EXU 的散线端口。
  // 当前先由 decoded_uop + RF operands 形成 execute_req_t；未来该请求由 riscv32_issue_queue 发出。
  // 接口必须使用 ex_req_valid/ex_req_ready/ex_req_bits，不能把固定为 1 的 valid 塞进 payload。
  riscv32_EXU #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) u_exu (
      .i_ex_pc(w_pc),
      .i_ex_rs1_data(w_rs1_data),
      .i_ex_rs2_data(w_rs2_data),
      .i_ex_rd_addr(w_rd_addr),
      .i_ex_imm(w_imm_final),
      .i_ex_alu_src1_sel(w_decode_ctrl.alu_src1_sel),
      .i_ex_alu_src2_sel(w_decode_ctrl.alu_src2_sel),
      .i_ex_alu_op(w_decode_ctrl.alu_op),
      .i_ex_branch_op(w_decode_ctrl.branch_op),
      .i_ex_branch_en(w_decode_ctrl.branch_en),
      .i_ex_jal_en(w_decode_ctrl.jal_en),
      .i_ex_jalr_en(w_decode_ctrl.jalr_en),

      // EXU completion is a single result record. Future EX/MEM register,
      // bypass network, and ROB completion port should preserve this boundary.
      .o_ex_result(w_ex_result),

      .i_ex_mem_cmd(w_decode_ctrl.mem_cmd),
      .i_ex_mem_size(w_decode_ctrl.mem_size),
      .i_ex_mem_unsigned(w_decode_ctrl.mem_unsigned),
      .i_ex_reg_wen(w_decode_ctrl.reg_wen),
      .i_ex_wb_sel(w_decode_ctrl.wb_sel)
  );

  // TODO(HP-TOP-7): 拆除“所有指令 EXU -> LSU -> WBU”的串行路径。
  // 只将 fu_type==FU_LSU 的 memory uop 发给 LSU；riscv32_int_alu、riscv32_branch_unit、LSU、riscv32_csr_exec 应分别输出
  // completion channel，再由 riscv32_completion_arbiter/ROB 接收。不要让普通 ALU 指令穿过 LSU。
  riscv32_LSU #(
      .DATA_WIDTH(DATA_WIDTH)
  ) u_lsu (
      // LSU consumes the whole EXU result record: address, store data, memory
      // command, size, sign mode, and writeback metadata stay together.
      .i_lsu_ex_result(w_ex_result),
      .o_lsu_result(w_lsu_result)
  );

  // TODO(HP-TOP-8): 建立 riscv32_completion_arbiter 和 riscv32_commit 后删除下面的 u_wbu_legacy。
  // execute completion 负责写 PRF/唤醒依赖，riscv32_commit 负责按 ROB 顺序提交异常、CSR、
  // store 和架构可见状态；这两个阶段不能继续由当前 WBU 混在一起表示。
  riscv32_WBU #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) u_wbu_legacy (
      // WBU consumes the LSU completion record. Writeback arbitration and
      // bypass sources should use structured result records, not top-level
      // reconstructed wires.
      .i_wbu_lsu_result(w_lsu_result),
      .i_wbu_csr_rdata (w_csr_rdata),

      .o_wbu_wdata(w_wbu_wdata),
      .o_wbu_waddr(w_wbu_waddr),
      .o_wbu_wen  (w_wbu_wen)
  );

  // TODO(HP-TOP-9): 创建 riscv32_sim_debug，并把下面全部 DPI scope/export 迁出 Core。
  // 流水线后 npc_get_pc_dpi/npc_get_inst_dpi 必须读取 commit packet，而不是 fetch PC/inst；
  // 否则 itrace、ftrace 和 DiffTest 会把尚未提交或错误路径指令当成架构执行结果。
  import "DPI-C" context function void npc_set_dpi_scope();
  initial begin
    npc_set_dpi_scope();
  end

  // expose PC and instruction
  export "DPI-C" function npc_get_pc_dpi;
  export "DPI-C" function npc_get_inst_dpi;

  function int npc_get_pc_dpi();
    npc_get_pc_dpi = w_pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = w_instruction;
  endfunction

  import "DPI-C" context function void ebreak_halt();

  // TODO(HP-TOP-10): 删除 decode 阶段直接 halt 的行为。
  // ebreak 应作为 exception/system uop 进入 ROB，只在 riscv32_commit 确认它是最老且未被 flush
  // 的指令后产生 commit_ebreak_o；riscv32_sim_debug 再根据该事件调用 ebreak_halt()。
  always_ff @(posedge clk) begin
    // Current C2 halts directly in top. In a pipelined or OoO CPU, ebreak/trap
    // should be carried to commit/retire instead of stopping at decode.
    if (rstn && w_decode_ctrl.ebreak_en) begin
      ebreak_halt();
    end
  end

endmodule
