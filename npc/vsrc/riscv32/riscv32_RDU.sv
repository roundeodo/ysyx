// TODO(HP-RDU-0): 完成 HP-RDU-1/2 时，将文件和模块一起重命名为 riscv32_redirect_arbiter。
// “RDU”没有说明它负责 redirect 仲裁和 flush boundary 生成；不要保留兼容别名，也不要在 top
// 再实现第二套 redirect mux。所有 redirect source 都通过 redirect_req_t 进入这个唯一仲裁点。
module riscv32_RDU #(
    parameter DATA_WIDTH = 32
) (
    // TODO(HP-RDU-1): 用统一 redirect channel/redirect_req_t 替换下面按来源命名的散线。
    // 输入来源至少包括 riscv32_branch_unit recovery、committed trap、committed mret 和 debug；每项请求携带
    // target_pc、reason，乱序阶段还必须携带 rob_idx/age。RDU 不应知道 ecall 译码信号。
    input logic                  i_ex_redirect_valid,
    input logic [DATA_WIDTH-1:0] i_ex_redirect_pc,

    input logic                  i_trap_redirect_valid,
    input logic [DATA_WIDTH-1:0] i_trap_vector_pc,

    input logic                  i_mret_redirect_valid,
    input logic [DATA_WIDTH-1:0] i_mret_pc,

    output logic                  o_redirect_valid,
    output logic [DATA_WIDTH-1:0] o_redirect_pc
);
  // TODO(HP-RDU-2): 重写下面仲裁逻辑并明确取消范围。
  // committed trap/mret/debug 的架构优先级高于推测分支恢复；多个推测 redirect 同时出现时，
  // 选择程序顺序最老者，并输出 flush boundary/rob_idx 给 riscv32_fetch_queue、riscv32_issue_queue、LSQ 和 ROB。
  // 当前仅输出 PC 不足以清除错误路径的后端状态。
  always_comb begin
    o_redirect_valid = i_ex_redirect_valid;
    o_redirect_pc    = i_ex_redirect_pc;

    if (i_trap_redirect_valid) begin
      o_redirect_valid = 1'b1;
      o_redirect_pc    = i_trap_vector_pc;
    end else if (i_mret_redirect_valid) begin
      o_redirect_valid = 1'b1;
      o_redirect_pc    = i_mret_pc;
    end
  end



endmodule
