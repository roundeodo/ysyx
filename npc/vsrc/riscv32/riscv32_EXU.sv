module riscv32_EXU
  import riscv32_pkg::*;
#(
    parameter ADDR_WIDTH = 5,
    parameter DATA_WIDTH = 32
) (

    // TODO(HP-EXU-1): 用 execute request channel 替换下面全部 data/control/pass-through 端口。
    // execute_req_t 应包含已经选择好的 operands、pc、imm、operation、physical destination
    // 和 rob_idx；端口使用 execute_req_valid_i/execute_req_ready_o/execute_req_i。
    // 当前 architectural rd 只用于过渡，加入 rename 后必须由 physical_rd + rob_idx 替代。
    // input data
    input logic [DATA_WIDTH-1:0] i_ex_pc,
    input logic [DATA_WIDTH-1:0] i_ex_rs1_data,
    input logic [DATA_WIDTH-1:0] i_ex_rs2_data,
    input logic [ADDR_WIDTH-1:0] i_ex_rd_addr,
    input logic [          31:0] i_ex_imm,

    //input control signal
    input alu_src1_sel_t i_ex_alu_src1_sel,
    input alu_src2_sel_t i_ex_alu_src2_sel,
    input alu_op_t       i_ex_alu_op,
    input branch_op_t    i_ex_branch_op,
    input logic          i_ex_branch_en,
    input logic          i_ex_jal_en,
    input logic          i_ex_jalr_en,

    //pass through signal in
    input mem_cmd_t  i_ex_mem_cmd,
    input mem_size_t i_ex_mem_size,
    input wb_sel_t   i_ex_wb_sel,
    input logic      i_ex_mem_unsigned,
    input logic      i_ex_reg_wen,

    // generated result
    output ex_result_t o_ex_result
);
  // ==========================================================================
  // EXU design boundary
  // ==========================================================================
  //
  // EXU 的长期定位不是“再 decode 一遍 RISC-V”，而是执行 internal operation。
  // IDU 已经把 opcode/funct 翻译成 alu_op/branch_op/jal/jalr/mem/wb 等控制。
  // EXU 只消费这些内部控制字段。
  //
  // 高性能 CPU 关联：
  //   未来乱序核里，EXU 会是 issue queue 后面的 integer ALU / branch unit / riscv32_agu。
  //   它收到的是 uop control，不应该再理解 ISA opcode。否则后面拆多执行单元、
  //   做 wakeup/select、做 branch recovery 时，decode 逻辑会分散到执行后端。
  //
  // 当前 C2 阶段：
  //   这个模块仍然是单周期组合 EXU：输入来自 ID/RF/top，输出直接给 IFU/LSU/WBU。
  //
  // 面向高性能 CPU 的设计方向：
  //   1. EXU 输入最终不应该直接来自 architectural rs1/rs2，而应该来自 issue queue
  //      选择出来的 ready operands，控制字段来自 uop。
  //   2. i_ex_rd_addr 当前是 architectural rd。未来 rename 后应替换或扩展为 physical
  //      destination tag，同时保留 ROB index 用于 precise exception/commit。
  //   3. ex_result_t 当前只保存功能结果。未来应扩展 wakeup tag、ROB index、exception
  //      metadata、branch recovery metadata，并通过 valid/ready 或执行单元完成端口输出。
  //   4. 当前 ALU/branch/address 计算放在一个 EXU 中。未来可以按 function class 拆成
  //      integer ALU、branch unit、riscv32_agu、mul/div unit，但每个单元仍应输出结构化 result。
  //
  // ======
  // OPERAND SELECTION
  // ======
  // 高性能 CPU 关联：
  //   alu_src*_sel 是 decode 后的 operand select，不是 ISA opcode。
  //   当前用它在 EXU 内选择 rs1/zero/pc 和 rs2/imm；未来多发射/乱序中，
  //   这些选择通常会在 rename/dispatch 阶段变成 uop 的 operand metadata。
  //
  //   当前 C2 为了简单，PC、立即数、寄存器值都直接进 EXU。
  //   未来高频设计中，branch target、load/store address 可能会拆到独立加法路径，
  //   以减少主 ALU 输入 mux 和关键路径压力。
  logic [DATA_WIDTH-1:0] alu_in1;
  logic [DATA_WIDTH-1:0] alu_in2;

  always_comb begin
    unique case (i_ex_alu_src1_sel)
      ALU_SRC1_RS1:  alu_in1 = i_ex_rs1_data;
      ALU_SRC1_ZERO: alu_in1 = 32'b0;
      ALU_SRC1_PC:   alu_in1 = i_ex_pc;
      default:       alu_in1 = 32'b0;
    endcase

    unique case (i_ex_alu_src2_sel)
      ALU_SRC2_RS2: alu_in2 = i_ex_rs2_data;
      ALU_SRC2_IMM: alu_in2 = i_ex_imm;
      default:      alu_in2 = 32'b0;
    endcase
  end

  // ======
  // OPERATION
  // ======
  // 高性能 CPU 关联：
  //   i_ex_alu_op 是 internal function code。EXU 不再解析 opcode/funct3/funct7。
  //   这是从 ISA 指令到 micro-op/uop 执行语义的关键边界。
  //
  //   当前所有 ALU op 共用一个组合 case。
  //   未来可以根据 alu_op/function class 把执行资源拆分：
  //     - ADD/SUB/SLT/SLTU: integer ALU
  //     - SLL/SRL/SRA: shifter
  //     - AND/OR/XOR: logic unit
  //   是否物理拆分取决于目标频率、面积、发射宽度和旁路网络复杂度。
  logic [DATA_WIDTH-1:0] alu_res;

  // TODO(HP-EXU-2): 建立独立 riscv32_int_alu 后，把下面 ALU operation case 移入该模块。
  // Operand select 可以暂时留在 execute-request 形成阶段；riscv32_int_alu 只接收 op/src1/src2，
  // 输出 result，不应知道 branch、memory、CSR、architectural rd 或 writeback select。
  always_comb begin
    unique case (i_ex_alu_op)
      ALU_ADD:  alu_res = alu_in1 + alu_in2;
      ALU_SUB:  alu_res = alu_in1 - alu_in2;
      ALU_SLL:  alu_res = alu_in1 << alu_in2[4:0];
      ALU_SLT:  alu_res = ($signed(alu_in1) < $signed(alu_in2)) ? 32'd1 : 32'd0;
      ALU_SLTU: alu_res = (alu_in1 < alu_in2) ? 32'd1 : 32'd0;
      ALU_XOR:  alu_res = alu_in1 ^ alu_in2;
      ALU_SRL:  alu_res = alu_in1 >> alu_in2[4:0];
      ALU_SRA:  alu_res = $signed(alu_in1) >>> alu_in2[4:0];
      ALU_OR:   alu_res = alu_in1 | alu_in2;
      ALU_AND:  alu_res = alu_in1 & alu_in2;
      default:  alu_res = 'd0;
    endcase
  end


  // ======
  // REDIRECTION
  // ======
  // 高性能 CPU 关联：
  //   redirect_valid/redirect_pc 是前端恢复接口，不应命名为 jump。
  //   当前 redirect 来源是 jal/jalr/taken branch；未来还会包括 branch mispredict、
  //   exception、interrupt、mret、debug redirect。
  //
  //   当前 branch 在 EXU 里解析条件并立即 redirect。
  //   未来有分支预测后，uop 还需要携带 predicted direction/target、branch tag、
  //   branch mask、ROB index。riscv32_branch_unit 比较真实结果与预测结果，只在错误时产生 recovery
  //   redirect，并通知前端和后端清理错误路径状态。
  logic                  branch_taken;
  logic                  branch_condition;
  logic                  redirect_valid;
  logic [DATA_WIDTH-1:0] redirect_pc;

  // TODO(HP-EXU-3): 建立 riscv32_branch_unit，并把从 branch condition 到 redirect 生成的整段逻辑移入。
  // riscv32_branch_unit 输入需包含 predicted_taken/target、pc、rob_idx 和 branch tag；输出 completion 以及
  // 仅在预测错误时有效的 redirect_req_t。JAL/JALR 也归 riscv32_branch_unit，而不是留在通用 riscv32_int_alu。
  always_comb begin : gen_branch_condition
    case (i_ex_branch_op)
      BR_BEQ:  branch_condition = i_ex_rs1_data == i_ex_rs2_data;
      BR_BNE:  branch_condition = i_ex_rs1_data != i_ex_rs2_data;
      BR_BLT:  branch_condition = $signed(i_ex_rs1_data) < $signed(i_ex_rs2_data);
      BR_BGE:  branch_condition = $signed(i_ex_rs1_data) >= $signed(i_ex_rs2_data);
      BR_BLTU: branch_condition = i_ex_rs1_data < i_ex_rs2_data;
      BR_BGEU: branch_condition = i_ex_rs1_data >= i_ex_rs2_data;
      default: branch_condition = 0;
    endcase
    branch_taken = i_ex_branch_en && branch_condition;
  end

  assign redirect_valid = i_ex_jal_en || i_ex_jalr_en || branch_taken;

  always_comb begin : gen_redirect_pc
    if (i_ex_jalr_en) begin
      redirect_pc = (i_ex_rs1_data + i_ex_imm) & ~32'h1;
    end else if (i_ex_jal_en || branch_taken) begin
      redirect_pc = i_ex_pc + i_ex_imm;
    end else begin
      redirect_pc = '0;
    end
  end

  // TODO(HP-EXU-4): 建立 riscv32_agu 路径，专门执行 load/store 的 rs1+imm 地址生成。
  // memory uop 的结果应送 LSU request/LSQ，不能再与普通 ALU result 一起强制经过 LSU。
  // riscv32_agu 还应生成 misalignment/badaddr metadata，最终异常由 ROB/Commit 精确处理。

  // EXU result packing. Keep this as the single writer of o_ex_result.
  //
  // 高性能 CPU 关联：
  //   o_ex_result 是执行完成记录。当前直接给后级组合消费；未来可以进入 EX/MEM
  //   pipeline register、bypass network、writeback arbitration、ROB completion port。
  //
  //   这里保持单一打包点有两个目的：
  //     1. 所有输出字段有统一默认值，新增字段时不容易漏赋值。
  //     2. 后续把组合输出改成 valid/ready completion port 时，只需要替换这个边界。
  //
  //   未来可能扩展的字段：
  //     physical_rd, rob_idx, exception_valid, exception_cause, badaddr,
  //     branch_mispredict, branch_tag, replay/flush metadata。
  // TODO(HP-EXU-5): 用 completion channel 替换 o_ex_result，并删除 payload 内固定为 1 的 valid。
  // riscv32_int_alu/riscv32_branch_unit/riscv32_agu 各自输出 valid/ready/bits；bits 中至少携带 result、physical_rd、rob_idx、
  // exception 和 branch recovery metadata。完成后本模块可退化为执行单元集合或被删除。
  always_comb begin : pack_ex_result
    o_ex_result                = '0;

    o_ex_result.valid          = 1'b1;
    o_ex_result.alu_res        = alu_res;
    o_ex_result.pc_plus_4      = i_ex_pc + 32'd4;
    o_ex_result.redirect_valid = redirect_valid;
    o_ex_result.redirect_pc    = redirect_pc;
    o_ex_result.store_data     = i_ex_rs2_data;
    o_ex_result.rd_addr        = i_ex_rd_addr;
    o_ex_result.mem_cmd        = i_ex_mem_cmd;
    o_ex_result.mem_size       = i_ex_mem_size;
    o_ex_result.mem_unsigned   = i_ex_mem_unsigned;
    o_ex_result.wb_sel         = i_ex_wb_sel;
    o_ex_result.reg_wen        = i_ex_reg_wen;
  end


endmodule
