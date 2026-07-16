module riscv32_IDU
  import riscv32_pkg::*;
#(
    parameter DATA_WIDTH = 32,
    parameter IMM_LENGTH = 12
) (
    input logic [DATA_WIDTH-1:0] i_id_instruction,
    output logic [6:0] o_id_opcode,
    output logic [ISA_REG_ADDR_W-1:0] o_id_rd_addr,
    output logic [ISA_REG_ADDR_W-1:0] o_id_rs2_addr,
    output logic [ISA_REG_ADDR_W-1:0] o_id_rs1_addr,
    output logic [2:0] o_id_funct_3,
    output logic [6:0] o_id_funct_7,
    output logic [11:0] o_id_funct_12,
    output logic [31:0] o_id_imm_I,
    output logic [31:0] o_id_imm_S,
    output logic [31:0] o_id_imm_U,
    output logic [31:0] o_id_imm_B,
    output logic [31:0] o_id_imm_J
);
  // ==========================================================================
  // IDU design boundary
  // ==========================================================================
  //
  // 这个模块的长期定位不是“完整 decode”，而是 decode frontend 的前半段：
  //
  //   instruction bits -> raw instruction fields + all immediate formats
  //
  // 当前 C2 单周期 CPU 里它叫 IDU；未来做高性能 CPU 时，它更接近
  // predecode / field extraction / immediate generation 这一级。
  //
  // 为什么要这样划分：
  //   1. 高性能 CPU 里，ISA decode 只应该在少数固定位置发生。
  //      如果 IDU、EXU、LSU、WBU 都各自理解 opcode/funct，后续做流水线、
  //      rename、dispatch、issue queue 时会很难维护一致性。
  //
  //   2. Rename 阶段需要 rd/rs1/rs2 这些 raw register specifier。
  //      它不应该从 scattered decode logic 里反推源/目的寄存器。
  //
  //   3. Branch/JAL target 的早期计算依赖 B/J immediate。
  //      未来做前端预测、BTB 校验、decode-stage target generation 时，
  //      这些 immediate 应该在 decode 前端已经稳定产生。
  //
  //   4. Decoder 负责把 raw fields 翻译成 decode_ctrl_t，也就是
  //      internal control / micro-op metadata 的雏形。
  //      IDU 不产生 alu_op、mem_cmd、reg_wen、wb_sel。
  //
  // 因此本模块必须保持“窄职责”：
  //   允许做：
  //     - opcode / rd / rs1 / rs2 / funct3 / funct7 / funct12 字段切分
  //     - imm_I / imm_S / imm_B / imm_U / imm_J 拼接和符号扩展
  //
  //   不允许做：
  //     - 不判断当前指令是不是 load/store/branch/jal/system
  //     - 不产生 alu_op / branch_op / mem_cmd / wb_sel / reg_wen
  //     - 不判断 RV32E 的 x16-x31 是否非法
  //     - 不因为当前是 RV32E 就把寄存器字段截断成 4 bit
  //
  // 已完成：
  //   - funct12 已经作为 raw field 输出，供 Decoder 区分 ebreak/ecall/csr。
  //   - imm_I/S/B/U/J 已经全部从 raw instruction 直接生成。
  //   - rd/rs1/rs2 端口已经使用 riscv32_pkg 中的 ISA_REG_ADDR_W。
  //
  // Future note: optional cleanup after top/Decoder are stable
  //   当前先保留清晰端口，便于 C2 调试。
  //   后续如果进入多发射 decode，可以考虑把这些输出收进 packed struct：
  //     decoded_fields_t fields;
  //
  //   struct 可包含：
  //     opcode, rd, rs1, rs2, funct3, funct7, funct12, imm_I/S/B/U/J
  //
  //   高性能 CPU 关联：
  //     多发射前端会同时处理多条 instruction，array-of-struct 比大量散线更容易扩展。
  //     但当前阶段先不要过早抽象，先保证单发射 RV32E NPC 的行为正确。

  assign o_id_opcode = i_id_instruction[6:0];
  assign o_id_rd_addr = i_id_instruction[11:7];
  assign o_id_rs2_addr = i_id_instruction[24:20];
  assign o_id_rs1_addr = i_id_instruction[19:15];
  assign o_id_funct_3 = i_id_instruction[14:12];
  assign o_id_funct_7 = i_id_instruction[31:25];
  assign o_id_funct_12 = i_id_instruction[31:20];

  assign o_id_imm_I = {{(DATA_WIDTH - IMM_LENGTH) {i_id_instruction[31]}}, i_id_instruction[31:20]};
  assign o_id_imm_S = {
    {(DATA_WIDTH - IMM_LENGTH) {i_id_instruction[31]}},
    i_id_instruction[31:25],
    i_id_instruction[11:7]
  };
  assign o_id_imm_U = {i_id_instruction[31:12], {IMM_LENGTH{1'b0}}};
  assign o_id_imm_B = {
    {20{i_id_instruction[31]}},
    i_id_instruction[7],
    i_id_instruction[30:25],
    i_id_instruction[11:8],
    1'b0
  };
  assign o_id_imm_J = {
    {12{i_id_instruction[31]}},
    i_id_instruction[19:12],
    i_id_instruction[20],
    i_id_instruction[30:21],
    1'b0
  };
endmodule
