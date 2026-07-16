// TODO(HP-IDU-0): 保留 IDU 作为对外阶段边界，不把顶层模块改名为 decoder。
// 当前 IDU 负责接收 fetch packet，并完成字段提取、立即数生成、合法性检查和 decoded uop 生成。
// 当 DECODE_WIDTH > 1 时，再把“单条指令到单个 decoded_uop_t”的纯组合逻辑抽成
// riscv32_decode_lane，并在本模块内例化 DECODE_WIDTH 个 lane；valid/ready、lane 压缩、异常顺序和
// 下游 backpressure 仍由 riscv32_idu 管理。这样保留常见的 ID stage/IDU 边界，同时允许复制 decoder。
module riscv32_idu
  import riscv32_pkg::*;
(
    // TODO(HP-IDU-1): 旧 field-extractor IDU 已删除并合并到本文件；先完成这里，恢复编译。
    // 用一个 fetch_packet_t 输入替换下面全部 raw-field 输入，并把输出改成 decoded_uop_t。
    // 推荐端口形式：
    //   input  fetch_packet_t fetch_packet_i,
    //   output decoded_uop_t  decoded_uop_o
    // 当前 i_idu_* 端口只作为迁移参照；新端口接通后将它们全部删除。
    // Legacy raw-field ports: migrate their extraction into this IDU, then delete all of them.
    input logic [6:0] i_idu_opcode,
    input logic [2:0] i_idu_funct_3,
    input logic [6:0] i_idu_funct_7,

    // funct12
    input logic [11:0] i_idu_funct_12,

    //register related
    input logic [ISA_REG_ADDR_W-1:0] i_idu_rd_addr,
    input logic [ISA_REG_ADDR_W-1:0] i_idu_rs1_addr,
    /* verilator lint_off UNUSEDSIGNAL */
    // Legacy ctrl-only interface does not carry rs2 yet. HP-IDU-1/4 will move it into decoded_uop_t.
    input logic [ISA_REG_ADDR_W-1:0] i_idu_rs2_addr,
    /* verilator lint_on UNUSEDSIGNAL */

    // to top/EXU/LSU/WBU/future pipeline register
    output decode_ctrl_t o_idu_ctrl
);
  // TODO(HP-IDU-2): 在这里从 fetch_packet_i.instruction 提取所有 raw fields。
  // 直接在本 TODO 下声明 opcode/funct/rd/rs 局部信号并赋值；然后把本文件中所有
  // i_idu_opcode/i_idu_funct_*/i_idu_*_addr 引用替换成这些局部信号。
  // 字段位置：opcode[6:0]、rd[11:7]、funct3[14:12]、rs1[19:15]、
  // rs2[24:20]、funct7[31:25]、funct12[31:20]。
  // 保留完整 5-bit rs/rd；RV32I 的 x0-x31 都是合法架构寄存器。
  // 可直接按下面骨架补全：
  // logic [31:0] instruction;
  // logic [6:0]  opcode, funct7;
  // logic [2:0]  funct3;
  // logic [11:0] funct12;
  // logic [4:0]  rd_addr, rs1_addr, rs2_addr;
  // assign instruction = fetch_packet_i.instruction;
  // assign opcode      = instruction[6:0];
  // assign rd_addr     = instruction[11:7];
  // assign funct3      = instruction[14:12];
  // assign rs1_addr    = instruction[19:15];
  // assign rs2_addr    = instruction[24:20];
  // assign funct7      = instruction[31:25];
  // assign funct12     = instruction[31:20];

  // TODO(HP-IDU-3): 紧接着在这里生成 imm_I/S/B/U/J，并根据当前译码选择最终 imm。
  // 最终只写入 decoded_uop_o.imm，不要把五种 immediate 继续输出给 top。
  // 可直接按下面公式生成；B/J 最低位由指令编码隐含为 0：
  // logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  // assign imm_i = {{20{instruction[31]}}, instruction[31:20]};
  // assign imm_s = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
  // assign imm_b = {{19{instruction[31]}}, instruction[31], instruction[7],
  //                 instruction[30:25], instruction[11:8], 1'b0};
  // assign imm_u = {instruction[31:12], 12'b0};
  // assign imm_j = {{11{instruction[31]}}, instruction[31], instruction[19:12],
  //                 instruction[20], instruction[30:21], 1'b0};
  // 在 decoded_uop_o 默认清零后，根据 imm_sel 把其中一个值写入 decoded_uop_o.imm；完成后
  // 删除 top.sv 的 w_imm_* 和 immediate mux。

  // IDU uses decode_ctrl_t as the single decoded-control output.
  // Later CSR/trap support should keep illegal/exception metadata centralized in
  // decode and let the commit/trap boundary handle precise architectural effects.

  // ======
  // Main decode logic
  //
  // 设计原则：
  //
  // 1. Decode 集中化
  //    opcode/funct3/funct7 只在 IDU 里集中解析。
  //    EXU 后续只看 alu_op / branch_op，不再重复 decode ISA。
  //
  // 2. 输出 internal operation
  //    把 RISC-V 指令翻译成 CPU 内部控制：
  //      alu_op
  //      branch_op
  //      imm_sel
  //      mem_cmd
  //      wb_sel
  //
  // 3. 默认安全 nop
  //    默认不写寄存器、不访存、不跳转。
  //    遇到非法指令时，禁止一切体系结构状态修改。
  //
  // 4. exception-ready
  //    当前 stage 可以暂时不处理 illegal_instr，
  //    但这个信号已经为未来 trap/CSR/commit 做准备。
  // ======
  // TODO(HP-IDU-4): 将下面 always_comb 的单一输出从 o_idu_ctrl 迁移到 decoded_uop_o。
  // 建议第一行先写 `decoded_uop_o = '0;`，再写入 pc、instruction、rs1/rs2/rd、imm 和控制字段。
  // 同时为每类指令准确设置 use_rs1/use_rs2 和 fu_type：
  //   ALU-R/branch/store: use_rs1=1,use_rs2=1
  //   ALU-I/load/jalr/CSR-register: use_rs1=1
  //   lui/auipc/jal/ecall/mret: 根据语义均不读取无关寄存器
  // Rename 只允许依据 use_rs1/use_rs2 建立依赖，后端不得重新检查 opcode。
  // 迁移完成后删除 decode_ctrl_t 和所有 o_idu_ctrl 引用。
  always_comb begin
    o_idu_ctrl.valid           = 1'b1;

    o_idu_ctrl.imm_sel         = IMM_NONE;

    o_idu_ctrl.alu_src1_sel    = ALU_SRC1_RS1;
    o_idu_ctrl.alu_src2_sel    = ALU_SRC2_RS2;
    o_idu_ctrl.alu_op          = ALU_ADD;

    o_idu_ctrl.branch_op       = BR_NONE;
    o_idu_ctrl.branch_en       = 1'b0;
    o_idu_ctrl.jal_en          = 1'b0;
    o_idu_ctrl.jalr_en         = 1'b0;

    o_idu_ctrl.mem_cmd         = MEM_CMD_NONE;
    o_idu_ctrl.mem_size        = MEM_SIZE_WORD;
    o_idu_ctrl.mem_unsigned    = 1'b0;

    o_idu_ctrl.wb_sel          = WB_ALU_RES;
    o_idu_ctrl.reg_wen         = 1'b0;

    o_idu_ctrl.ebreak_en       = 1'b0;
    o_idu_ctrl.illegal_instr   = 1'b0;
    o_idu_ctrl.exception_cause = EXC_NONE;

    o_idu_ctrl.csr_op          = CSR_OP_NONE;
    o_idu_ctrl.csr_ren         = 1'b0;
    o_idu_ctrl.csr_wren        = 1'b0;
    o_idu_ctrl.ecall_en        = 1'b0;
    o_idu_ctrl.mret_en         = 1'b0;

    unique case (i_idu_opcode)
      // R-type
      // add/sub/sll/slkt/sltu/xor/srl/sra/or/and
      // use rd, rs1, rs2; RV32I accepts x0-x31 for every register operand.
      OPCODE_R_TYPE: begin
        o_idu_ctrl.reg_wen      = 1'b1;
        o_idu_ctrl.wb_sel       = WB_ALU_RES;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_RS2;

        unique case (i_idu_funct_3)
            FUNCT3_ADD_SUB: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_ADD;
              end else if (i_idu_funct_7 == FUNCT7_ALT) begin
                o_idu_ctrl.alu_op = ALU_SUB;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SLL: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_SLL;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SLT: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_SLT;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SLTU: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_SLTU;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_XOR: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_XOR;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SRL_SRA: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_SRL;
              end else if (i_idu_funct_7 == FUNCT7_ALT) begin
                o_idu_ctrl.alu_op = ALU_SRA;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_OR: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_OR;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_AND: begin
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_AND;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            default: begin
              o_idu_ctrl.illegal_instr   = 1'b1;
              o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
        endcase
      end

      // ==========================================================
      // I-type arithmetic
      //
      // addi/slti/sltiu/xori/ori/andi/slli/srli/srai
      //
      // 使用字段：
      //   rd, rs1
      //
      // 注意：
      //   instruction[24:20] 在 I-type 中是 immediate/shamt，
      //   不是 rs2，所以不能检查 i_idu_rs2_addr。
      // ==========================================================

      OPCODE_I_TYPE: begin
        o_idu_ctrl.imm_sel      = IMM_I;
        o_idu_ctrl.reg_wen      = 1'b1;
        o_idu_ctrl.wb_sel       = WB_ALU_RES;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;

        unique case (i_idu_funct_3)
            FUNCT3_ADD_SUB: begin
              // addi
              o_idu_ctrl.alu_op = ALU_ADD;
            end

            FUNCT3_SLT: begin
              // slti
              o_idu_ctrl.alu_op = ALU_SLT;
            end

            FUNCT3_SLTU: begin
              // sltiu
              o_idu_ctrl.alu_op = ALU_SLTU;
            end

            FUNCT3_XOR: begin
              // xori
              o_idu_ctrl.alu_op = ALU_XOR;
            end

            FUNCT3_OR: begin
              // ori
              o_idu_ctrl.alu_op = ALU_OR;
            end

            FUNCT3_AND: begin
              // andi
              o_idu_ctrl.alu_op = ALU_AND;
            end

            FUNCT3_SLL: begin
              // slli
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_SLL;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SRL_SRA: begin
              // srli / srai
              if (i_idu_funct_7 == FUNCT7_BASE) begin
                o_idu_ctrl.alu_op = ALU_SRL;
              end else if (i_idu_funct_7 == FUNCT7_ALT) begin
                o_idu_ctrl.alu_op = ALU_SRA;
              end else begin
                o_idu_ctrl.illegal_instr   = 1'b1;
                o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            default: begin
              o_idu_ctrl.illegal_instr   = 1'b1;
              o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
        endcase
      end

      // ==========================================================
      // LUI
      //
      // rd = imm_U
      //
      // 当前实现：
      //   ALU result = zero + imm_U
      //
      // 使用字段：
      //   rd
      // ==========================================================

      OPCODE_LUI: begin
        o_idu_ctrl.imm_sel      = IMM_U;
        o_idu_ctrl.reg_wen      = 1'b1;
        o_idu_ctrl.wb_sel       = WB_ALU_RES;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_ZERO;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_idu_ctrl.alu_op       = ALU_ADD;

      end


      // ==========================================================
      // AUIPC
      //
      // rd = pc + imm_U
      //
      // 使用字段：
      //   rd
      // ==========================================================

      OPCODE_AUIPC: begin
        o_idu_ctrl.imm_sel      = IMM_U;
        o_idu_ctrl.reg_wen      = 1'b1;
        o_idu_ctrl.wb_sel       = WB_ALU_RES;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_PC;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_idu_ctrl.alu_op       = ALU_ADD;

      end


      // ==========================================================
      // JAL
      //
      // rd = pc + 4
      // pc = pc + imm_J
      //
      // 使用字段：
      //   rd
      // ==========================================================

      OPCODE_JAL: begin
        o_idu_ctrl.imm_sel      = IMM_J;
        o_idu_ctrl.reg_wen      = 1'b1;
        o_idu_ctrl.wb_sel       = WB_PC4;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_PC;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_idu_ctrl.alu_op       = ALU_ADD;
        o_idu_ctrl.jal_en       = 1'b1;

      end


      // ==========================================================
      // JALR
      //
      // rd = pc + 4
      // pc = (rs1 + imm_I) & ~1
      //
      // 使用字段：
      //   rd, rs1
      //
      // 额外规则：
      //   标准 jalr 要求 funct3 == 3'b000。
      // ==========================================================

      OPCODE_JALR: begin
        o_idu_ctrl.imm_sel      = IMM_I;
        o_idu_ctrl.reg_wen      = 1'b1;
        o_idu_ctrl.wb_sel       = WB_PC4;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_idu_ctrl.alu_op       = ALU_ADD;
        o_idu_ctrl.jalr_en      = 1'b1;

        if (i_idu_funct_3 != 3'b000) begin
          o_idu_ctrl.illegal_instr   = 1'b1;
          o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end
      end


      // ==========================================================
      // BRANCH
      //
      // beq/bne/blt/bge/bltu/bgeu
      //
      // target = pc + imm_B
      //
      // 使用字段：
      //   rs1, rs2
      //
      // 注意：
      //   IDU 只输出 branch_op。
      //   branch_taken 应该由 EXU 根据 branch_op、rs1_data、rs2_data 计算。
      // ==========================================================

      OPCODE_BRANCH: begin
        o_idu_ctrl.imm_sel      = IMM_B;
        o_idu_ctrl.branch_en    = 1'b1;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_PC;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_idu_ctrl.alu_op       = ALU_ADD;

        unique case (i_idu_funct_3)
            FUNCT3_BEQ:  o_idu_ctrl.branch_op = BR_BEQ;
            FUNCT3_BNE:  o_idu_ctrl.branch_op = BR_BNE;
            FUNCT3_BLT:  o_idu_ctrl.branch_op = BR_BLT;
            FUNCT3_BGE:  o_idu_ctrl.branch_op = BR_BGE;
            FUNCT3_BLTU: o_idu_ctrl.branch_op = BR_BLTU;
            FUNCT3_BGEU: o_idu_ctrl.branch_op = BR_BGEU;

            default: begin
              o_idu_ctrl.illegal_instr   = 1'b1;
              o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
        endcase
      end


      // ==========================================================
      // LOAD
      //
      // lb/lh/lw/lbu/lhu
      //
      // addr = rs1 + imm_I
      // rd   = memory data
      //
      // 使用字段：
      //   rd, rs1
      // ==========================================================

      OPCODE_LOAD: begin
        o_idu_ctrl.imm_sel      = IMM_I;
        o_idu_ctrl.reg_wen      = 1'b1;
        o_idu_ctrl.wb_sel       = WB_MEM_RES;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_idu_ctrl.alu_op       = ALU_ADD;
        o_idu_ctrl.mem_cmd      = MEM_CMD_LOAD;

        unique case (i_idu_funct_3)
            FUNCT3_LB: begin
              o_idu_ctrl.mem_size     = MEM_SIZE_BYTE;
              o_idu_ctrl.mem_unsigned = 1'b0;
            end

            FUNCT3_LH: begin
              o_idu_ctrl.mem_size     = MEM_SIZE_HALF;
              o_idu_ctrl.mem_unsigned = 1'b0;
            end

            FUNCT3_LW: begin
              o_idu_ctrl.mem_size     = MEM_SIZE_WORD;
              o_idu_ctrl.mem_unsigned = 1'b0;
            end

            FUNCT3_LBU: begin
              o_idu_ctrl.mem_size     = MEM_SIZE_BYTE;
              o_idu_ctrl.mem_unsigned = 1'b1;
            end

            FUNCT3_LHU: begin
              o_idu_ctrl.mem_size     = MEM_SIZE_HALF;
              o_idu_ctrl.mem_unsigned = 1'b1;
            end

            default: begin
              o_idu_ctrl.illegal_instr   = 1'b1;
              o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
        endcase
      end


      // ==========================================================
      // STORE
      //
      // sb/sh/sw
      //
      // addr = rs1 + imm_S
      // memory[addr] = rs2
      //
      // 使用字段：
      //   rs1, rs2
      // ==========================================================

      OPCODE_STORE: begin
        o_idu_ctrl.imm_sel      = IMM_S;
        o_idu_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_idu_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_idu_ctrl.alu_op       = ALU_ADD;
        o_idu_ctrl.mem_cmd      = MEM_CMD_STORE;

        unique case (i_idu_funct_3)
            FUNCT3_SB: begin
              o_idu_ctrl.mem_size = MEM_SIZE_BYTE;
            end

            FUNCT3_SH: begin
              o_idu_ctrl.mem_size = MEM_SIZE_HALF;
            end

            FUNCT3_SW: begin
              o_idu_ctrl.mem_size = MEM_SIZE_WORD;
            end

            default: begin
              o_idu_ctrl.illegal_instr   = 1'b1;
              o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
        endcase
      end


      // ==========================================================
      // SYSTEM
      //
      // 当前只支持 ebreak。
      //
      // ebreak:
      //   opcode  = 1110011
      //   funct3  = 000
      //   funct12 = 001
      //   rd      = x0
      //   rs1     = x0
      //
      // 当前 NPC 用 ebreak 触发 DPI-C ebreak_halt()。
      // 未来如果实现异常系统，ebreak 可以对应 breakpoint exception。
      // ==========================================================

      // TODO(HP-IDU-5): 在迁移 SYSTEM decode 时统一产生异常/串行化 metadata。
      // ecall/ebreak/illegal 应设置 exception_valid + exception_cause；mret 和 CSR 写应标记
      // serializing，使它们未来只能在 ROB 头部修改 CSR/控制流。IDU 只能描述事件，
      // 不能直接写 CSR、redirect 或调用 DPI。
      OPCODE_SYSTEM: begin
        unique case (i_idu_funct_3)
          3'b000: begin
            if (i_idu_funct_12 == FUNCT12_ECALL &&
          i_idu_rd_addr  == 5'd0 &&
          i_idu_rs1_addr == 5'd0) begin
              o_idu_ctrl.ecall_en        = 1'b1;
              o_idu_ctrl.exception_cause = EXC_ECALL_M;
            end else if (i_idu_funct_12 == FUNCT12_EBREAK &&
                   i_idu_rd_addr  == 5'd0 &&
                   i_idu_rs1_addr == 5'd0) begin
              o_idu_ctrl.ebreak_en       = 1'b1;
              o_idu_ctrl.exception_cause = EXC_BREAKPOINT;
            end else if (i_idu_funct_12 == FUNCT12_MRET &&
                   i_idu_rd_addr  == 5'd0 &&
                   i_idu_rs1_addr == 5'd0) begin
              o_idu_ctrl.mret_en = 1'b1;
            end else begin
              o_idu_ctrl.illegal_instr   = 1'b1;
              o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
          end

          3'b001: begin  // CSRRW, pseudo csrw when rd == x0
            o_idu_ctrl.csr_op   = CSR_OP_RW;
            o_idu_ctrl.csr_ren  = (i_idu_rd_addr != 5'd0);
            o_idu_ctrl.csr_wren = 1'b1;
            o_idu_ctrl.reg_wen  = (i_idu_rd_addr != 5'd0);
            o_idu_ctrl.wb_sel   = WB_CSR;
          end

          3'b010: begin  // CSRRS, pseudo csrr when rs1 == x0
            o_idu_ctrl.csr_op   = CSR_OP_RS;
            o_idu_ctrl.csr_ren  = 1'b1;
            o_idu_ctrl.csr_wren = (i_idu_rs1_addr != 5'd0);
            o_idu_ctrl.reg_wen  = (i_idu_rd_addr != 5'd0);
            o_idu_ctrl.wb_sel   = WB_CSR;
          end

          3'b011: begin  // CSRRC
            o_idu_ctrl.csr_op   = CSR_OP_RC;
            o_idu_ctrl.csr_ren  = 1'b1;
            o_idu_ctrl.csr_wren = (i_idu_rs1_addr != 5'd0);
            o_idu_ctrl.reg_wen  = (i_idu_rd_addr != 5'd0);
            o_idu_ctrl.wb_sel   = WB_CSR;
          end

          default: begin
            o_idu_ctrl.illegal_instr   = 1'b1;
            o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
          end
        endcase
      end

      // ==========================================================
      // MISC-MEM
      //
      // 当前把 fence / fence.i 类指令暂时当作 nop。
      //
      // 为什么可以暂时这样：
      //   当前单周期 NPC 没有 cache、store buffer、乱序执行，
      //   也没有真实 memory ordering 问题。
      //
      // 未来 SoC / 高性能 CPU：
      //   fence 需要和 store buffer、cache、总线 ordering 交互。
      // ==========================================================

      OPCODE_MISC_MEM: begin
        o_idu_ctrl.imm_sel = IMM_I;
      end


      // ==========================================================
      // Unknown opcode
      // ==========================================================

      default: begin
        o_idu_ctrl.illegal_instr   = 1'b1;
        o_idu_ctrl.exception_cause = EXC_ILLEGAL_INST;
      end
    endcase

    // ============================================================
    // Final safety override for illegal instruction
    //
    // 非法指令不能修改体系结构状态。
    //
    // 当前 stage：
    //   还没有真正 trap/exception 处理，所以至少要保证：
    //     不写寄存器
    //     不读写内存
    //     不跳转
    //     不触发 ebreak
    //
    // 未来：
    //   illegal_instr 会进入 trap/commit 逻辑，
    //   由异常系统处理精确异常。
    // ============================================================

    // TODO(HP-IDU-6): 将这个 safety override 保留到 decoded_uop_t 版本。
    // exception_valid 时必须清除 reg_wen、memory side effect、branch side effect 和 CSR write；
    // 但不要清除 exception_cause、pc、instruction，ROB/riscv32_trap_ctrl 需要它们产生精确异常。
    if (o_idu_ctrl.illegal_instr) begin
      o_idu_ctrl.reg_wen      = 1'b0;
      o_idu_ctrl.mem_cmd      = MEM_CMD_NONE;

      o_idu_ctrl.branch_en    = 1'b0;
      o_idu_ctrl.branch_op    = BR_NONE;
      o_idu_ctrl.jal_en       = 1'b0;
      o_idu_ctrl.jalr_en      = 1'b0;

      o_idu_ctrl.ebreak_en    = 1'b0;

      o_idu_ctrl.wb_sel       = WB_ALU_RES;
      o_idu_ctrl.alu_op       = ALU_ADD;
      o_idu_ctrl.alu_src1_sel = ALU_SRC1_RS1;
      o_idu_ctrl.alu_src2_sel = ALU_SRC2_RS2;
      o_idu_ctrl.imm_sel      = IMM_NONE;

      o_idu_ctrl.csr_op       = CSR_OP_NONE;
      o_idu_ctrl.csr_ren      = 1'b0;
      o_idu_ctrl.csr_wren     = 1'b0;
      o_idu_ctrl.ecall_en     = 1'b0;
      o_idu_ctrl.mret_en      = 1'b0;
    end
  end


endmodule
