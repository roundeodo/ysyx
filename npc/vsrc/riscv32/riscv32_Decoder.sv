module riscv32_Decoder
  import riscv32_pkg::*;
(
    //from IDU
    input logic [6:0] i_dec_opcode,
    input logic [2:0] i_dec_funct_3,
    input logic [6:0] i_dec_funct_7,

    // funct12
    input logic [11:0] i_dec_funct_12,

    //register related
    input logic [ISA_REG_ADDR_W-1:0] i_dec_rd_addr,
    input logic [ISA_REG_ADDR_W-1:0] i_dec_rs1_addr,
    input logic [ISA_REG_ADDR_W-1:0] i_dec_rs2_addr,

    // to top/EXU/LSU/WBU/future pipeline register
    output decode_ctrl_t o_dec_ctrl
);
  // Decoder uses decode_ctrl_t as the single decoded-control output.
  // Later CSR/trap support should keep illegal/exception metadata centralized in
  // decode and let the commit/trap boundary handle precise architectural effects.

  // check if register address is valid (because only 16 regs in RV32E  reg_addr[4] == 1 -> x16-x31  illegal)
  function automatic logic is_rv32e_reg(input logic [ISA_REG_ADDR_W-1:0] reg_addr);
    is_rv32e_reg = (reg_addr[ISA_REG_ADDR_W-1] == 1'b0);
  endfunction

  // ======
  // Main decode logic
  //
  // 设计原则：
  //
  // 1. Decode 集中化
  //    opcode/funct3/funct7 只在 Decoder 里集中解析。
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
  always_comb begin
    o_dec_ctrl.valid           = 1'b1;

    o_dec_ctrl.imm_sel         = IMM_NONE;

    o_dec_ctrl.alu_src1_sel    = ALU_SRC1_RS1;
    o_dec_ctrl.alu_src2_sel    = ALU_SRC2_RS2;
    o_dec_ctrl.alu_op          = ALU_ADD;

    o_dec_ctrl.branch_op       = BR_NONE;
    o_dec_ctrl.branch_en       = 1'b0;
    o_dec_ctrl.jal_en          = 1'b0;
    o_dec_ctrl.jalr_en         = 1'b0;

    o_dec_ctrl.mem_cmd         = MEM_CMD_NONE;
    o_dec_ctrl.mem_size        = MEM_SIZE_WORD;
    o_dec_ctrl.mem_unsigned    = 1'b0;

    o_dec_ctrl.wb_sel          = WB_ALU_RES;
    o_dec_ctrl.reg_wen         = 1'b0;

    o_dec_ctrl.ebreak_en       = 1'b0;
    o_dec_ctrl.illegal_instr   = 1'b0;
    o_dec_ctrl.exception_cause = EXC_NONE;

    o_dec_ctrl.csr_op          = CSR_OP_NONE;
    o_dec_ctrl.csr_ren         = 1'b0;
    o_dec_ctrl.csr_wren        = 1'b0;
    o_dec_ctrl.ecall_en        = 1'b0;
    o_dec_ctrl.mret_en         = 1'b0;

    unique case (i_dec_opcode)
      // R-type
      // add/sub/sll/slkt/sltu/xor/srl/sra/or/and
      // use  rd, rs1, rs2
      // in RV32E, those should be x0-x15
      OPCODE_R_TYPE: begin
        o_dec_ctrl.reg_wen      = 1'b1;
        o_dec_ctrl.wb_sel       = WB_ALU_RES;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_RS2;

        if (!is_rv32e_reg(
                i_dec_rd_addr
            ) || !is_rv32e_reg(
                i_dec_rs1_addr
            ) || !is_rv32e_reg(
                i_dec_rs2_addr
            )) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end else begin
          unique case (i_dec_funct_3)
            FUNCT3_ADD_SUB: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_ADD;
              end else if (i_dec_funct_7 == FUNCT7_ALT) begin
                o_dec_ctrl.alu_op = ALU_SUB;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SLL: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_SLL;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SLT: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_SLT;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SLTU: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_SLTU;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_XOR: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_XOR;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SRL_SRA: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_SRL;
              end else if (i_dec_funct_7 == FUNCT7_ALT) begin
                o_dec_ctrl.alu_op = ALU_SRA;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_OR: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_OR;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_AND: begin
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_AND;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            default: begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
          endcase
        end
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
      //   不是 rs2，所以不能检查 i_dec_rs2_addr。
      // ==========================================================

      OPCODE_I_TYPE: begin
        o_dec_ctrl.imm_sel      = IMM_I;
        o_dec_ctrl.reg_wen      = 1'b1;
        o_dec_ctrl.wb_sel       = WB_ALU_RES;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;

        if (!is_rv32e_reg(i_dec_rd_addr) || !is_rv32e_reg(i_dec_rs1_addr)) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end else begin
          unique case (i_dec_funct_3)
            FUNCT3_ADD_SUB: begin
              // addi
              o_dec_ctrl.alu_op = ALU_ADD;
            end

            FUNCT3_SLT: begin
              // slti
              o_dec_ctrl.alu_op = ALU_SLT;
            end

            FUNCT3_SLTU: begin
              // sltiu
              o_dec_ctrl.alu_op = ALU_SLTU;
            end

            FUNCT3_XOR: begin
              // xori
              o_dec_ctrl.alu_op = ALU_XOR;
            end

            FUNCT3_OR: begin
              // ori
              o_dec_ctrl.alu_op = ALU_OR;
            end

            FUNCT3_AND: begin
              // andi
              o_dec_ctrl.alu_op = ALU_AND;
            end

            FUNCT3_SLL: begin
              // slli
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_SLL;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            FUNCT3_SRL_SRA: begin
              // srli / srai
              if (i_dec_funct_7 == FUNCT7_BASE) begin
                o_dec_ctrl.alu_op = ALU_SRL;
              end else if (i_dec_funct_7 == FUNCT7_ALT) begin
                o_dec_ctrl.alu_op = ALU_SRA;
              end else begin
                o_dec_ctrl.illegal_instr   = 1'b1;
                o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
              end
            end

            default: begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
          endcase
        end
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
        o_dec_ctrl.imm_sel      = IMM_U;
        o_dec_ctrl.reg_wen      = 1'b1;
        o_dec_ctrl.wb_sel       = WB_ALU_RES;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_ZERO;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_dec_ctrl.alu_op       = ALU_ADD;

        if (!is_rv32e_reg(i_dec_rd_addr)) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end
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
        o_dec_ctrl.imm_sel      = IMM_U;
        o_dec_ctrl.reg_wen      = 1'b1;
        o_dec_ctrl.wb_sel       = WB_ALU_RES;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_PC;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_dec_ctrl.alu_op       = ALU_ADD;

        if (!is_rv32e_reg(i_dec_rd_addr)) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end
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
        o_dec_ctrl.imm_sel      = IMM_J;
        o_dec_ctrl.reg_wen      = 1'b1;
        o_dec_ctrl.wb_sel       = WB_PC4;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_PC;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_dec_ctrl.alu_op       = ALU_ADD;
        o_dec_ctrl.jal_en       = 1'b1;

        if (!is_rv32e_reg(i_dec_rd_addr)) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end
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
        o_dec_ctrl.imm_sel      = IMM_I;
        o_dec_ctrl.reg_wen      = 1'b1;
        o_dec_ctrl.wb_sel       = WB_PC4;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_dec_ctrl.alu_op       = ALU_ADD;
        o_dec_ctrl.jalr_en      = 1'b1;

        if (!is_rv32e_reg(
                i_dec_rd_addr
            ) || !is_rv32e_reg(
                i_dec_rs1_addr
            ) || i_dec_funct_3 != 3'b000) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
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
      //   Decoder 只输出 branch_op。
      //   branch_taken 应该由 EXU 根据 branch_op、rs1_data、rs2_data 计算。
      // ==========================================================

      OPCODE_BRANCH: begin
        o_dec_ctrl.imm_sel      = IMM_B;
        o_dec_ctrl.branch_en    = 1'b1;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_PC;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_dec_ctrl.alu_op       = ALU_ADD;

        if (!is_rv32e_reg(i_dec_rs1_addr) || !is_rv32e_reg(i_dec_rs2_addr)) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end else begin
          unique case (i_dec_funct_3)
            FUNCT3_BEQ:  o_dec_ctrl.branch_op = BR_BEQ;
            FUNCT3_BNE:  o_dec_ctrl.branch_op = BR_BNE;
            FUNCT3_BLT:  o_dec_ctrl.branch_op = BR_BLT;
            FUNCT3_BGE:  o_dec_ctrl.branch_op = BR_BGE;
            FUNCT3_BLTU: o_dec_ctrl.branch_op = BR_BLTU;
            FUNCT3_BGEU: o_dec_ctrl.branch_op = BR_BGEU;

            default: begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
          endcase
        end
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
        o_dec_ctrl.imm_sel      = IMM_I;
        o_dec_ctrl.reg_wen      = 1'b1;
        o_dec_ctrl.wb_sel       = WB_MEM_RES;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_dec_ctrl.alu_op       = ALU_ADD;
        o_dec_ctrl.mem_cmd      = MEM_CMD_LOAD;

        if (!is_rv32e_reg(i_dec_rd_addr) || !is_rv32e_reg(i_dec_rs1_addr)) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end else begin
          unique case (i_dec_funct_3)
            FUNCT3_LB: begin
              o_dec_ctrl.mem_size     = MEM_SIZE_BYTE;
              o_dec_ctrl.mem_unsigned = 1'b0;
            end

            FUNCT3_LH: begin
              o_dec_ctrl.mem_size     = MEM_SIZE_HALF;
              o_dec_ctrl.mem_unsigned = 1'b0;
            end

            FUNCT3_LW: begin
              o_dec_ctrl.mem_size     = MEM_SIZE_WORD;
              o_dec_ctrl.mem_unsigned = 1'b0;
            end

            FUNCT3_LBU: begin
              o_dec_ctrl.mem_size     = MEM_SIZE_BYTE;
              o_dec_ctrl.mem_unsigned = 1'b1;
            end

            FUNCT3_LHU: begin
              o_dec_ctrl.mem_size     = MEM_SIZE_HALF;
              o_dec_ctrl.mem_unsigned = 1'b1;
            end

            default: begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
          endcase
        end
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
        o_dec_ctrl.imm_sel      = IMM_S;
        o_dec_ctrl.alu_src1_sel = ALU_SRC1_RS1;
        o_dec_ctrl.alu_src2_sel = ALU_SRC2_IMM;
        o_dec_ctrl.alu_op       = ALU_ADD;
        o_dec_ctrl.mem_cmd      = MEM_CMD_STORE;

        if (!is_rv32e_reg(i_dec_rs1_addr) || !is_rv32e_reg(i_dec_rs2_addr)) begin
          o_dec_ctrl.illegal_instr   = 1'b1;
          o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
        end else begin
          unique case (i_dec_funct_3)
            FUNCT3_SB: begin
              o_dec_ctrl.mem_size = MEM_SIZE_BYTE;
            end

            FUNCT3_SH: begin
              o_dec_ctrl.mem_size = MEM_SIZE_HALF;
            end

            FUNCT3_SW: begin
              o_dec_ctrl.mem_size = MEM_SIZE_WORD;
            end

            default: begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
          endcase
        end
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

      OPCODE_SYSTEM: begin
        unique case (i_dec_funct_3)
          3'b000: begin
            if (i_dec_funct_12 == FUNCT12_ECALL &&
          i_dec_rd_addr  == 5'd0 &&
          i_dec_rs1_addr == 5'd0) begin
              o_dec_ctrl.ecall_en        = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ECALL_M;
            end else if (i_dec_funct_12 == FUNCT12_EBREAK &&
                   i_dec_rd_addr  == 5'd0 &&
                   i_dec_rs1_addr == 5'd0) begin
              o_dec_ctrl.ebreak_en       = 1'b1;
              o_dec_ctrl.exception_cause = EXC_BREAKPOINT;
            end else if (i_dec_funct_12 == FUNCT12_MRET &&
                   i_dec_rd_addr  == 5'd0 &&
                   i_dec_rs1_addr == 5'd0) begin
              o_dec_ctrl.mret_en = 1'b1;
            end else begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end
          end

          3'b001: begin  // CSRRW, pseudo csrw when rd == x0
            if (!is_rv32e_reg(i_dec_rd_addr) || !is_rv32e_reg(i_dec_rs1_addr)) begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end else begin
              o_dec_ctrl.csr_op   = CSR_OP_RW;
              o_dec_ctrl.csr_ren  = (i_dec_rd_addr != 5'd0);
              o_dec_ctrl.csr_wren = 1'b1;
              o_dec_ctrl.reg_wen  = (i_dec_rd_addr != 5'd0);
              o_dec_ctrl.wb_sel   = WB_CSR;
            end
          end

          3'b010: begin  // CSRRS, pseudo csrr when rs1 == x0
            if (!is_rv32e_reg(i_dec_rd_addr) || !is_rv32e_reg(i_dec_rs1_addr)) begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end else begin
              o_dec_ctrl.csr_op   = CSR_OP_RS;
              o_dec_ctrl.csr_ren  = 1'b1;
              o_dec_ctrl.csr_wren = (i_dec_rs1_addr != 5'd0);
              o_dec_ctrl.reg_wen  = (i_dec_rd_addr != 5'd0);
              o_dec_ctrl.wb_sel   = WB_CSR;
            end
          end

          3'b011: begin  // CSRRC
            if (!is_rv32e_reg(i_dec_rd_addr) || !is_rv32e_reg(i_dec_rs1_addr)) begin
              o_dec_ctrl.illegal_instr   = 1'b1;
              o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
            end else begin
              o_dec_ctrl.csr_op   = CSR_OP_RC;
              o_dec_ctrl.csr_ren  = 1'b1;
              o_dec_ctrl.csr_wren = (i_dec_rs1_addr != 5'd0);
              o_dec_ctrl.reg_wen  = (i_dec_rd_addr != 5'd0);
              o_dec_ctrl.wb_sel   = WB_CSR;
            end
          end

          default: begin
            o_dec_ctrl.illegal_instr   = 1'b1;
            o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
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
        o_dec_ctrl.imm_sel = IMM_I;
      end


      // ==========================================================
      // Unknown opcode
      // ==========================================================

      default: begin
        o_dec_ctrl.illegal_instr   = 1'b1;
        o_dec_ctrl.exception_cause = EXC_ILLEGAL_INST;
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

    if (o_dec_ctrl.illegal_instr) begin
      o_dec_ctrl.reg_wen      = 1'b0;
      o_dec_ctrl.mem_cmd      = MEM_CMD_NONE;

      o_dec_ctrl.branch_en    = 1'b0;
      o_dec_ctrl.branch_op    = BR_NONE;
      o_dec_ctrl.jal_en       = 1'b0;
      o_dec_ctrl.jalr_en      = 1'b0;

      o_dec_ctrl.ebreak_en    = 1'b0;

      o_dec_ctrl.wb_sel       = WB_ALU_RES;
      o_dec_ctrl.alu_op       = ALU_ADD;
      o_dec_ctrl.alu_src1_sel = ALU_SRC1_RS1;
      o_dec_ctrl.alu_src2_sel = ALU_SRC2_RS2;
      o_dec_ctrl.imm_sel      = IMM_NONE;

      o_dec_ctrl.csr_op       = CSR_OP_NONE;
      o_dec_ctrl.csr_ren      = 1'b0;
      o_dec_ctrl.csr_wren     = 1'b0;
      o_dec_ctrl.ecall_en     = 1'b0;
      o_dec_ctrl.mret_en      = 1'b0;
    end
  end


endmodule
